-- Michael B Chang

-- Third Party Imports
require 'torch'
require 'nn'
require 'optim'
require 'image'
require 'xlua'
require 'Base'
require 'sys'
require 'rmsprop'
require 'pl'
require 'data_utils'

-- Local Imports
local model_utils = require 'model_utils'
local D = require 'DataLoader'
local D2 = require 'datasaver'
require 'logging_utils'

------------------------------------- Init -------------------------------------
local cmd = torch.CmdLine()
cmd:option('-mode', "exp", 'exp | pred | simulate | save')
cmd:option('-root', "logslink", 'subdirectory to save logs')
cmd:option('-model', "ff", 'ff | lstmobj | lstmtime')
cmd:option('-name', "ff_sim_test", 'experiment name')
cmd:option('-plot', true, 'turn on/off plot')
cmd:option('-traincfgs', "[:-2:2-:]", 'which train configurations')
cmd:option('-testcfgs', "[:-2:2-:]", 'which test configurations')
cmd:option('-batch_size', 50, 'batch size')
cmd:option('-accel', false, 'use acceleration data')
cmd:option('-opt', "optimrmsprop", 'rmsprop | adam | optimsrmsprop')
cmd:option('-server', "op", 'pc = personal | op = openmind')
cmd:option('-relative', true, 'relative state vs absolute state')
cmd:option('-shuffle', false, 'shuffle batches')
cmd:option('-lr', 0.001, 'learning rate')
cmd:option('-lrdecay', 0.99, 'learning rate annealing')
cmd:option('-sharpen', 1, 'sharpen exponent')
cmd:option('-lrdecayafter', 50, 'number of epochs before turning down lr')
cmd:option('-max_epochs', 100, 'max number of epochs')
cmd:option('-diff', false, 'use relative context position and velocity state')
cmd:option('-rnn_dim', 50, 'hidden dimension')
cmd:option('-object_dim', 9, 'number of input features')
cmd:option('-layers', 3, 'layers in network')
cmd:option('-seed', true, 'manual seed or not')
cmd:option('-print_every', 100, 'print every number of batches')
cmd:option('-save_every', 20, 'save every number of epochs')
cmd:text()

-- parse input params
mp = cmd:parse(arg)

if mp.server == 'pc' then
    mp.root = 'logs'
    mp.winsize = 10 -- total number of frames
    mp.num_past = 2 --10
    mp.num_future = 1 --10
	mp.dataset_folder = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/data/nonstationary_lite'--dataset_files_subsampled_dense_np2' --'hoho'
    mp.traincfgs = '[:-2:2-:]'
    mp.testcfgs = '[:-2:2-:]'
	mp.batch_size = 10 --1
    mp.lrdecay = 0.99
	mp.seq_length = 10
	mp.num_threads = 1
    mp.print_every = 1
    mp.plot = false--true
	mp.cuda = false
	mp.cunn = false
    -- mp.max_epochs = 5
else
	mp.winsize = 80  -- total number of frames
    mp.num_past = 2 -- total number of past frames
    mp.num_future = 1
	mp.dataset_folder = '/om/data/public/mbchang/physics-data/13'
	mp.seq_length = 10
	mp.num_threads = 4
    mp.plot = false
	mp.cuda = true
	mp.cunn = true
end

local M
if mp.model == 'lstmobj' then
    M = require 'model_new'
elseif mp.model == 'lstmtime' then
    M = require 'lstm_model'
elseif mp.model == 'ff' then
    M = require 'feed_forward_model'
else
    error('Unrecognized model')
end


-- world constants
local G_w_width, G_w_height = 384.0, 288.0
local G_max_velocity, G_min_velocity = 2*3000,-2*3000
local subsamp = 5


if mp.num_past < 2 or mp.num_future < 2 then assert(not(mp.accel)) end
if mp.accel then mp.object_dim = mp.object_dim+2 end
mp.input_dim = mp.object_dim*mp.num_past
mp.out_dim = mp.object_dim*mp.num_future
mp.savedir = mp.root .. '/' .. mp.name

if mp.seed then torch.manualSeed(123) end
if mp.cuda then require 'cutorch' end
if mp.cunn then require 'cunn' end

local optimizer, optim_state
if mp.opt == 'rmsprop' then
    optimizer = rmsprop
    optim_state = {learningRate   = mp.lr,
                   momentumDecay  = 0.1,
                   updateDecay    = 0.01}
elseif mp.opt == 'optimrmsprop' then
    optimizer = optim.rmsprop
    optim_state = {learningRate   = mp.lr}
elseif mp.opt == 'adam' then
    optimizer = optim.adam
    optim_state = {learningRate   = mp.lr}
end

local model, train_loader, test_loader, modelfile

------------------------------- Helper Functions -------------------------------

-- initialize
function inittrain(preload, model_path)
    print("Network parameters:")
    print(mp)
    local data_loader_args = {mp.dataset_folder,
                              mp.shuffle,
                              mp.cuda}
    train_loader = D.create('trainset', unpack(data_loader_args))
    val_loader =  D.create('valset', unpack(data_loader_args))  -- using testcfgs
    test_loader = D.create('testset', unpack(data_loader_args))
    train_test_loader = D.create('trainset', unpack(data_loader_args))
    model = M.create(mp, preload, model_path)

    trainLogger = optim.Logger(paths.concat(mp.savedir ..'/', 'train.log'))
    experimentLogger = optim.Logger(paths.concat(mp.savedir ..'/', 'experiment.log'))
    if mp.plot == false then
        trainLogger.showPlot = false
        experimentLogger.showPlot = false
    end
    print("Initialized Network")
end

function initsavebatches(preload, model_path)
    mp.cuda = false
    mp.cunn = false
    mp.shuffle = false
    print("Network parameters:")
    print(mp)
    local data_loader_args = {mp.dataset_folder,
                              mp.batch_size,
                              mp.shuffle,
                              mp.relative,
                              mp.num_past,
                              mp.winsize}
    train_loader = D2.create('trainset', mp.traincfgs, unpack(data_loader_args))
    val_loader =  D2.create('valset', mp.testcfgs, unpack(data_loader_args))  -- using testcfgs
    test_loader = D2.create('testset', mp.testcfgs, unpack(data_loader_args))

    train_loader:save_sequential_batches()
    val_loader:save_sequential_batches()
    test_loader:save_sequential_batches()
end

function inittest(preload, model_path)
    print("Network parameters:")
    print(mp)
    local data_loader_args = {mp.dataset_folder,
                              mp.shuffle,
                              mp.cuda}
    test_loader = D.create('testset', unpack(data_loader_args))  -- TODO: Testing on trainset
    model = M.create(mp, preload, model_path)
    if preload then mp = torch.load(model_path).mp end
    modelfile = model_path
    print("Initialized Network")
end


-- closure: returns loss, grad_params
function feval_train(params_)  -- params_ should be first argument

    local batch = train_loader:sample_priority_batch(mp.sharpen)
    local loss, _ = model:fp(params_, batch)
    local grad = model:bp(batch)

    train_loader.priority_sampler:update_batch_weight(train_loader.current_sampled_id, loss)
    collectgarbage()
    return loss, grad -- f(x), df/dx
end

-- trains for one epoch
function train(epoch_num)
    local new_params, train_loss
    local loss_run_avg = 0
    for t = 1,train_loader.num_batches do
        train_loader.priority_sampler:set_epcnum(epoch_num)--set_epcnum
        -- xlua.progress(t, train_loader.num_batches)
        new_params, train_loss = optimizer(feval_train, model.theta.params, optim_state)  -- next batch
        assert(new_params == model.theta.params)
        if t % mp.print_every == 0 then
            print(string.format("epoch %2d\titeration %2d\tloss = %6.8f\tgradnorm = %6.4e\tbatch = %4d\thardest batch: %4d \twith loss %6.8f lr = %6.4e",
                    epoch_num, t, train_loss[1],
                    model.theta.grad_params:norm(),
                    train_loader.current_sampled_id,
                    train_loader.priority_sampler:get_hardest_batch()[2],
                    train_loader.priority_sampler:get_hardest_batch()[1],
                    optim_state.learningRate))
        end
        loss_run_avg = loss_run_avg + train_loss[1]
        trainLogger:add{['log MSE loss (train set)'] =  torch.log(train_loss[1])}
        trainLogger:style{['log MSE loss (train set)'] = '~'}
        if mp.plot then trainLogger:plot() end
        if mp.cuda then cutorch.synchronize() end
        collectgarbage()
    end
    return loss_run_avg/train_loader.num_batches -- running avg of training loss.
end

-- test on dataset
function test(dataloader, params_, saveoutput)
    local sum_loss = 0
    for i = 1,dataloader.num_batches do
        if mp.server == 'pc ' then xlua.progress(i, dataloader.num_batches) end

        local batch = dataloader:sample_sequential_batch()
        local test_loss, prediction = model:fp(params_, batch)

        -- hacky for backwards compatability
        local this, context, y, mask, config, start, finish, context_future = unpack(batch)


        if mp.model == 'lstmtime' then
            -- print(this:size())  -- (bsize, mp.winsize-1, mp.object_dim)
            -- print(context:size())  -- (bsize, mp.seq_length, mp.winsize-1, mp.object_dim)
            -- print(y:size())  -- (bsize, mp.winsize-1, mp.object_dim)
            -- print(context_future:size())  -- (bsize, mp.seq_length mp.winsize-1, mp.object_dim)

            -- take care of relative position
            if mp.relative then
                prediction[{{},{},{1,4}}] = prediction[{{},{},{1,4}}] +
                                                this[{{},{},{1,4}}]  -- TODO RESIZE THIS?
                y[{{},{},{1,4}}] = y[{{},{},{1,4}}] + this[{{},{},{1,4}}] -- add back because relative  -- TODO RESIZE THIS?
            end
        else
            context_future = crop_future(context_future,
                                        {context_future:size(1), mp.seq_length,
                                        mp.winsize-mp.num_past, mp.object_dim},
                                        {3,mp.num_future})
            context_future:reshape(context_future:size(1),
                        context_future:size(2), mp.num_future, mp.object_dim)
            context = context:reshape(context:size(1), context:size(2),
                                        mp.num_past, mp.object_dim)

            -- reshape to -- (num_samples x num_future x 8)
            prediction = prediction:reshape(mp.batch_size, mp.num_future, mp.object_dim)   -- TODO RESIZE THIS
            this = this:reshape(mp.batch_size, mp.num_past, mp.object_dim)   -- TODO RESIZE THIS
            y = crop_future(y, {y:size(1), mp.winsize-mp.num_past, mp.object_dim}, {2,mp.num_future})  -- TODO RESIZE THIS
            y = y:reshape(mp.batch_size, mp.num_future, mp.object_dim)   -- TODO RESIZE THIS

            -- take care of relative position
            if mp.relative then
                prediction[{{},{},{1,4}}] = prediction[{{},{},{1,4}}] +
                    this[{{},{-1},{1,4}}]:expandAs(prediction[{{},{},{1,4}}])  -- TODO RESIZE THIS?
                y[{{},{},{1,4}}] = y[{{},{},{1,4}}] +
                    this[{{},{-1},{1,4}}]:expandAs(y[{{},{},{1,4}}]) -- add back because relative  -- TODO RESIZE THIS?
            end
        end

        -- save
        if saveoutput then
            save_example_prediction({this, context, y, prediction, context_future},
                                    {config, start, finish},
                                    modelfile,
                                    dataloader,
                                    mp.num_future)
        end
        sum_loss = sum_loss + test_loss
    end
    local avg_loss = sum_loss/dataloader.num_batches
    collectgarbage()
    return avg_loss
end

-- this: (mp.batch_size, mp.num_past, mp.object_dim)
-- prediction: (mp.batch_size, mp.num_future, mp.object_dim)
function update_position(this, pred)
    local this, pred = this:clone(), pred:clone()
    local lastpos = (this[{{},{-1},{1,2}}]:clone()*G_w_width)
    local lastvel = (this[{{},{-1},{3,4}}]:clone()*G_max_velocity/1000*subsamp)
    local currpos = (pred[{{},{},{1,2}}]:clone()*G_w_width)
    local currvel = (pred[{{},{},{3,4}}]:clone()*G_max_velocity/1000*subsamp)

    -- this is length n+1
    local pos = torch.cat({lastpos, currpos},2)
    local vel = torch.cat({lastvel, currvel},2)

    -- there may be a bug here
    -- take the last part (future)
    for i = 1,pos:size(2)-1 do
        pos[{{},{i+1},{}}] = pos[{{},{i},{}}] + vel[{{},{i},{}}]  -- last dim=2
    end

    -- normalize again
    pos = pos/G_w_width
    assert(pos[{{},{1},{}}]:size(1) == pred:size(1))

    pred[{{},{},{1,2}}] = pos[{{},{2,-1},{}}]  -- reassign back to pred this should be: pos[{{},{2,-1},{}}]
    return pred
end


-- test on dataset
-- assumption: that you predict 1 out
--[[
    Want:
        the data given to still have windowsize of 20.
        But we want to only predict for 1 timestep,
        But we want the context to have full windowsize. Perhaps we can
            have a flag to set? The full context, starting at the time prediction
            starts until the end of the window, should be passed through
        But also you need the full context and context_future to be passed in.
            Where to do the processing?
        Given the pred (batch_size, num_future, obj_dim) we will take the
        first time slice: [{{},{1}}] of that

-- ]]
--
function simulate(dataloader, params_, saveoutput, numsteps)
    assert(mp.num_future == 1 and numsteps <= mp.winsize-mp.num_past)
    local sum_loss = 0
    for i = 1,dataloader.num_batches do
        if mp.server == 'pc ' then xlua.progress(i, dataloader.num_batches) end

        -- get data
        local this_orig, context_orig, y_orig, mask, config, start, finish, context_future_orig = unpack(dataloader:sample_sequential_batch())
        local this, context = this_orig:clone(), context_orig:clone()
        context_future = context_future_orig:clone():reshape(mp.batch_size, mp.seq_length, mp.winsize-mp.num_past, mp.object_dim)

        -- at this point:
        -- this (bsize, numpast*objdim)  -- TODO RESIZE THIS
        -- context (bsize, mp.seq_length, mp.numpast*mp.objdim)
        -- y_orig (bsize, (mp.winsize-mp.num_past)*objdim)
        -- context_future (bsize, mp.seqlength, (mp.winsize-mp.num_past)*mp.objdim)

        -- allocate space, already assume reshape
        local pred_sim = model_utils.transfer_data(torch.zeros(mp.batch_size, numsteps, mp.object_dim), mp.cuda)  -- TODO RESIZE THIS

        for t = 1,numsteps do
            -- the t-th timestep in the future
            y = y_orig:clone():reshape(mp.batch_size, mp.winsize-mp.num_past, mp.object_dim)[{{},{t},{}}]  -- increment time in y; may need to reshape  -- TODO RESIZE THIS
            y = y:reshape(mp.batch_size, 1*mp.object_dim)  -- TODO RESIZE THIS

            print('this')
            print(this[{{1}}])
            print('context')
            print(context[{{1}}])
            print('y')
            print(y[{{1}}])

            local modified_batch = {this, context, y, mask, config, start,
                                        finish, context_future_orig}

            local test_loss, prediction = model:fp(params_, modified_batch, true)  -- TODO Does mask make sense here? Well, yes right? because mask only has to do with the objects


            print('pred')
            print(prediction[{{1}}])
            -- local test_loss, prediction = model:fp(params_, {this=this,context=context}, y, mask)  -- TODO Does mask make sense here? Well, yes right? because mask only has to do with the objects

            prediction = prediction:reshape(mp.batch_size, mp.num_future, mp.object_dim)  -- TODO RESIZE THIS
            this = this:reshape(mp.batch_size, mp.num_past, mp.object_dim)  -- TODO RESIZE THIS
            context = context:reshape(mp.batch_size, mp.seq_length, mp.num_past, mp.object_dim)

            print(prediction:size())
            print(this:size())
            print(context:size())
            assert(false)

            if mp.relative then
                prediction[{{},{},{1,4}}] = prediction[{{},{},{1,4}}] + this[{{},{-1},{1,4}}]:expandAs(prediction[{{},{},{1,4}}])  -- TODO RESIZE THIS?
            end

            -- restore object properties
            prediction[{{},{},{5,-1}}] = this[{{},{-1},{5,-1}}]

            -- here you want to add velocity to position
            -- prediction: (batchsize, mp.num_future, mp.object_dim)
            prediction = update_position(this, prediction)

            -- update this and context
            -- chop off first time step and then add in next one
            if mp.num_past > 1 then
                this = torch.cat({this[{{},{2,-1},{}}]:clone(), prediction}, 2)  -- you can add y in here  -- TODO RESIZE THIS
                context = torch.cat({context[{{},{},{2,-1},{}}]:clone(), context_future[{{},{},{t},{}}]:clone()},3)
            else
                assert(mp.num_past == 1)
                this = prediction:clone()  -- just use prev prediction as input
                context = context_future[{{},{},{t},{}}]:clone()
            end

            -- reshape it back
            this = this:reshape(mp.batch_size, mp.num_past*mp.object_dim)  -- TODO RESIZE THIS
            context = context:reshape(mp.batch_size, mp.seq_length, mp.num_past*mp.object_dim)

            pred_sim[{{},{t},{}}] = prediction  -- note that this is just one timestep  -- you can add y in here
            sum_loss = sum_loss + test_loss
        end

        -- reshape to -- (num_samples x num_future x 8)
        this_orig = this_orig:reshape(this_orig:size(1), mp.num_past, mp.object_dim)  -- will render the original past  -- TODO RESIZE THIS
        context_orig = context_orig:reshape(context_orig:size(1),mp.seq_length,mp.num_past,mp.object_dim)
        y_orig = y_orig:reshape(y_orig:size(1), mp.winsize-mp.num_past, mp.object_dim) -- will render the original future  -- TODO RESIZE THIS
        context_future_orig = context_future_orig:reshape(mp.batch_size, mp.seq_length, mp.winsize-mp.num_past, mp.object_dim)

        if mp.relative then
            y_orig = y_orig + this_orig[{{},{-1}}]:expandAs(y_orig)  -- TODO RESIZE THIS
        end

        -- now crop only the number of timesteps you need; pred_sim is also this many timesteps
        y_orig = y_orig[{{},{1,numsteps},{}}]  -- TODO RESIZE THIS
        context_future_orig = context_future_orig[{{},{},{1,numsteps},{}}]

        if saveoutput then
            save_example_prediction({this_orig, context_orig, y_orig, pred_sim, context_future_orig},
                                    {config, start, finish},
                                    modelfile,
                                    dataloader,
                                    numsteps)
        end
    end
    local avg_loss = sum_loss/dataloader.num_batches/numsteps
    collectgarbage()
    return avg_loss
end

-- simulate two balls for now, but this should be made more general
-- actually you should make this more general.
-- there is no concept of ground truth here?
-- or you can make the ground truth go as far as there are timesteps available
function simulate_all(dataloader, params_, saveoutput, numsteps)
    print('hahahaha')
    assert(mp.num_future == 1 and numsteps <= mp.winsize-mp.num_past)
    for i = 1,dataloader.num_batches do
        if mp.server == 'pc ' then xlua.progress(i, dataloader.num_batches) end

        -- get data
        local this_orig, context_orig, y_orig, mask, config, start, finish, context_future_orig = unpack(dataloader:sample_sequential_batch())

        -- print('this_orig')
        -- print(this_orig[{{1}}])
        -- print('context_orig')
        -- print(context_orig[{{1}}])
        -- print('y_orig')
        -- print(y_orig[{{1}}])
        -- print('context_future_orig')
        -- print(context_future_orig[{{1}}])


        -- past: (bsize, mp.seq_length+1, mp.numpast*mp.objdim)
        -- future: (bsize, mp.seq_length+1, (mp.winsize-mp.numpast), mp.objdim)
        local past = torch.cat({this_orig:reshape(
                    this_orig:size(1),1,this_orig:size(2)), context_orig},2)
        local future = torch.cat({y_orig:reshape(
                    y_orig:size(1),1,y_orig:size(2)), context_future_orig},2)

        -- print('past')
        -- print(past[{{1}}])
        -- print('future')
        -- print(future[{{1}}])


        -- reshape future
        future = future:reshape(mp.batch_size, mp.seq_length+1,
                                mp.winsize-mp.num_past, mp.object_dim)

        -- good up to here

        local pred_sim = model_utils.transfer_data(
                            torch.zeros(mp.batch_size, mp.seq_length+1,
                                        numsteps, mp.object_dim),
                            mp.cuda)
        local num_particles = torch.find(mask,1)[1] + 1

        print(future[{{1}}])

        -- loop through time
        for t = 1, numsteps do

            print('))))))))))))))))))))))))))))))))')
            print('t'..t)

            -- for each particle, update to the next timestep, given
            -- the past configuration of everybody

            for j = 1, num_particles do
                print('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
                print('particle'..j)
                -- construct batch
                local this = torch.squeeze(past[{{},{j}}])

                local context
                if j == 1 then
                    context = past[{{},{j+1,-1}}]
                elseif j == mp.seq_length+1 then
                    -- tricky thing here: num_particles may not
                    -- be the same as mp.seq_length+1!
                    context = past[{{},{1,-2}}]
                else
                    context = torch.cat({past[{{},{1,j-1}}],
                                                        past[{{},{j+1,-1}}]},2)
                end

                local y = torch.squeeze(future[{{},{j},{t}}])

                -- local context_future = torch.cat({future[{{},{1,j-1},{t}}],
                --                                 future[{{},{j+1,-1},{t}}]},2)

                -- consistent to simulate() up to here for the first particle

                print('this')
                print(this[{{1}}])
                print('context')
                print(context[{{1}}])
                print('y')
                print(y[{{1}}])
                print(this:size())
                print(context:size())
                print(y:size())

                local batch = {this, context, y, mask, config, start,
                                finish, _}

                -- predict
                local _, pred = model:fp(params_,batch,true)

                -- good up to here for first particle

                print('pred')
                print(pred[{{1}}])
                -- assert(false)


                pred = pred:reshape(mp.batch_size, mp.num_future, mp.object_dim)
                this = this:reshape(mp.batch_size, mp.num_past, mp.object_dim)
                context = context:reshape(mp.batch_size, mp.seq_length,
                                            mp.num_past, mp.object_dim)

                print(pred:size())
                print(this:size())
                print(context:size())

                -- relative coords
                if mp.relative then
                    pred[{{},{},{1,4}}] = pred[{{},{},{1,4}}] +
                                            this[{{},{-1},{1,4}}]:expandAs(
                                            pred[{{},{},{1,4}}])
                end

                -- restore object properties
                pred[{{},{},{5,-1}}] = this[{{},{-1},{5,-1}}]

                print(pred[{{1}}])
                -- update position
                pred = update_position(this, pred)
                print(pred[{{1}}])

                -- write into pred_sim
                pred_sim[{{},{j},{t},{}}] = pred
                -- sum_loss = sum_loss + test_loss
                print(pred_sim[{{1}}])
                print('<<<<<<<<<<<<<<<<<<<<<<<<')
            end
            print('pred sim '..t)
            print(pred_sim[{{1},{1,2}}])

            -- update past for next timestep
            -- update future for next timestep:
            -- to be honest, future can be anything
            -- so we can just keep future stale
            past = past:reshape(mp.batch_size, mp.seq_length+1,
                                mp.num_past, mp.object_dim)
            print('past '..t..' before update')
            print(past[{{1},{1,2}}])
            if mp.num_past > 1 then
                past = torch.cat({past[{{},{},{2,-1},{}}],
                                    pred_sim[{{},{},{t},{}}]}, 3)
            else
                assert(mp.num_past == 1)
                past = pred_sim[{{},{},{t},{}}]:clone()
            end
            print('past '..t..' after update')
            print(past[{{1},{1,2}}])

            past = past:reshape(mp.batch_size, mp.seq_length+1,
                                mp.num_past*mp.object_dim)

            print('((((((((((((((((((((((((')
        end

        -- at this point, pred_sim should be all filled out
        -- break pred_sim into this and context_future
        -- recall: pred_sim: (batch_size,seq_length+1,numsteps,object_dim)
        local this_pred = torch.squeeze(pred_sim[{{},{1}}])
        local context_pred = pred_sim[{{},{2,-1}}]

        print('this_pred')
        print(this_pred[{{1}}])
        print('context_pred')
        print(context_pred[{{1}}])

        -- reshape things
        this_orig = this_orig:reshape(this_orig:size(1), mp.num_past, mp.object_dim)  -- will render the original past  -- TODO RESIZE THIS
        context_orig = context_orig:reshape(context_orig:size(1),mp.seq_length,mp.num_past,mp.object_dim)
        y_orig = y_orig:reshape(y_orig:size(1), mp.winsize-mp.num_past, mp.object_dim) -- will render the original future

        if mp.relative then
            y_orig = y_orig + this_orig[{{},{-1}}]:expandAs(y_orig)  -- TODO RESIZE THIS
        end

        -- crop the number of timesteps
        y_orig = y_orig[{{},{1,numsteps},{}}]

        print(this_orig:size())
        print(context_orig:size())
        print(y_orig:size())
        print(this_pred:size())
        print(context_pred:size())
        -- assert(false)
        -- when you save, you will replace context_future_orig
        if saveoutput then
            save_example_prediction({this_orig, context_orig, y_orig,
                                    this_pred, context_pred},
                                    {config, start, finish},
                                    modelfile,
                                    dataloader,
                                    numsteps)
        end
    end
    collectgarbage()
end


function save_example_prediction(example, description, modelfile_, dataloader, numsteps)
    --[[
        example: {this, context, y, prediction, context_future}
        description: {config, start, finish}
        modelfile_: like '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/logs/lalala/network.t7'

        will save to something like:
            logs/<experiment-name>/predictions/<config.h5>


        -- the reshaping should not happen here!
    --]]

    --unpack
    local this, context, y, prediction, context_future = unpack(example)
    local config, start, finish = unpack(description)

    local subfolder = mp.savedir .. '/' .. 'predictions/'
    if not paths.dirp(subfolder) then paths.mkdir(subfolder) end
    local save_path = mp.savedir .. '/' .. 'predictions/' ..
                                config..'_['..start..','..finish..'].h5'

    if mp.cuda then
        prediction = prediction:float()
        this = this:float()
        context = context:float()
        y = y:float()
        context_future = context_future:float()
    end

    -- For now, just save it as hdf5. You can feed it back in later if you'd like
    save_to_hdf5(save_path, {pred=prediction, this=this, context=context,
                                y=y, context_future=context_future})
end

-- runs experiment
function experiment()
    torch.setnumthreads(mp.num_threads)
    print('<torch> set nb of threads to ' .. torch.getnumthreads())
    local train_losses, val_losses, test_losses = {},{},{}
    for i = 1, mp.max_epochs do
        print('Learning rate is now '..optim_state.learningRate)
        train(i)
        local train_loss = test(train_test_loader, model.theta.params, false)
        local val_loss = test(val_loader, model.theta.params, false)
        local test_loss = test(test_loader, model.theta.params, false)
        print('train loss\t'..train_loss..'\tval loss\t'..val_loss..'\ttest_loss\t'..test_loss)

        -- Save logs
        experimentLogger:add{['log MSE loss (train set)'] =  torch.log(train_loss),
                             ['log MSE loss (val set)'] =  torch.log(val_loss),
                             ['log MSE loss (test set)'] =  torch.log(test_loss)}
        experimentLogger:style{['log MSE loss (train set)'] = '~',
                               ['log MSE loss (val set)'] = '~',
                               ['log MSE loss (test set)'] = '~'}
        train_losses[#train_losses+1] = train_loss
        val_losses[#val_losses+1] = val_loss
        test_losses[#test_losses+1] = test_loss

        if i % mp.save_every == 0 then
            -- checkpoint(mp.savedir .. '/network'..'epc'..i..'.t7', model.network, mp) -- model.rnns[1]?
            -- checkpoint(mp.savedir .. '/params'..'epc'..i..'.t7', model.theta.params, mp)

            local model_file = string.format('%s/epoch%.2f_%.4f.t7', mp.savedir, i, val_loss)
            print('saving checkpoint to ' .. model_file)
            local checkpoint = {}
            checkpoint.model = model
            checkpoint.mp = mp
            checkpoint.train_losses = train_losses
            checkpoint.val_losses = val_losses
            torch.save(model_file, checkpoint)

            print('Saved model')
        end
        if mp.plot then experimentLogger:plot() end
        if mp.cuda then cutorch.synchronize() end

        -- here you can adjust the learning rate based on val loss
        if i >= mp.lrdecayafter then
            optim_state.learningRate =optim_state.learningRate*mp.lrdecay
        end
        collectgarbage()
    end
end

function checkpoint(savefile, data, mp_)
    if mp_.cuda then
        -- data = data:float()
        torch.save(savefile, data)
        -- data = data:cuda()
    else
        torch.save(savefile, data)
    end
    collectgarbage()
end

function run_experiment()
    inittrain(false)
    experiment()
end

function getLastSnapshot(network_name)
    local res_file = io.popen("ls -t "..mp.root..'/'..network_name.." | grep -i epoch | head -n 1")
    local status, result = pcall(function() return res_file:read():match( "^%s*(.-)%s*$" ) end)
    print(result)
    res_file:close()
    if not status then
        return false
    else
        return result
    end
end

function predict()
    local snapshot = getLastSnapshot(mp.name)
    print(snapshot)
    local checkpoint = torch.load(mp.savedir ..'/'..snapshot)
    mp = checkpoint.mp
    inittest(true, mp.savedir ..'/'..snapshot)  -- assuming the mp.savedir doesn't change

    -- inittest(true, mp.savedir ..'/'..'network.t7')  -- assuming the mp.savedir doesn't change
    -- print(test(test_loader, torch.load(mp.savedir..'/'..'params.t7'), true))
    print(test(test_loader,checkpoint.model.theta.params, true))
end

function predict_simulate()
    -- inittest(true, mp.savedir ..'/'..'network.t7')
    -- print(simulate(test_loader, torch.load(mp.savedir..'/'..'params.t7'), true, 5))

    local snapshot = getLastSnapshot(mp.name)
    local checkpoint = torch.load(mp.savedir ..'/'..snapshot)
    print(snapshot)
    mp = checkpoint.mp

    -- mp.winsize = 80  -- total number of frames
	-- mp.dataset_folder = '/om/data/public/mbchang/physics-data/13'

    inittest(true, mp.savedir ..'/'..snapshot)  -- assuming the mp.savedir doesn't change
    print(mp.winsize)
    print(simulate(test_loader, checkpoint.model.theta.params, true, 7))
end

function predict_simulate_all()
    -- inittest(true, mp.savedir ..'/'..'network.t7')
    -- print(simulate(test_loader, torch.load(mp.savedir..'/'..'params.t7'), true, 5))

    local snapshot = getLastSnapshot(mp.name)
    local checkpoint = torch.load(mp.savedir ..'/'..snapshot)
    print(snapshot)
    mp = checkpoint.mp
    inittest(true, mp.savedir ..'/'..snapshot)  -- assuming the mp.savedir doesn't change
    print(simulate_all(test_loader, checkpoint.model.theta.params, true, 7))
end


-- ------------------------------------- Main -------------------------------------
if mp.mode == 'exp' then
    run_experiment()
elseif mp.mode == 'sim' then
    -- predict_simulate()
    predict_simulate_all()
elseif mp.mode == 'save' then
    initsavebatches(false)
else
    predict()
end


-- inittest(false, mp.savedir ..'/'..'network.t7')
-- print(simulate(test_loader, model.theta.params, false, 3))
