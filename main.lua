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

-- Local Imports
local model_utils = require 'model_utils'
local D = require 'DataLoader'
local M = require 'model_new'
require 'logging_utils'

------------------------------------- Init -------------------------------------
-- Best val: 1/29/16: baselinesubsampledcontigdense_opt_adam_testcfgs_[:-2:2-:]_traincfgs_[:-2:2-:]_lr_0.005_batch_size_260.out

mp = lapp[[
   -e,--mode          (default "exp")           exp | pred
   -d,--root          (default "logslink")      	subdirectory to save logs
   -m,--model         (default "lstm")   		type of model tor train: lstm |
   -n,--name          (default "densenp2shuffle")
   -p,--plot          (default true)                    	plot while training
   -j,--traincfgs     (default "[:-2:2-:]")
   -k,--testcfgs      (default "[:-2:2-:]")
   -b,--batch_size    (default 80)
   -o,--opt           (default "optimrmsprop")       rmsprop | adam | optimrmsprop
   -c,--server		  (default "op")			pc=personal | op = openmind
   -t,--relative      (default "true")           relative state vs abs state
   -s,--shuffle  	  (default "true")
   -r,--lr            (default 0.0005)      	   learning rate
   -a,--lrdecay       (default 0.95)            annealing rate
   -i,--max_epochs    (default 20)           	maximum nb of iterations per batch, for LBFGS
   --rnn_dim          (default 128)
   --layers           (default 2)
   --seed             (default "true")
   --max_grad_norm    (default 10)
   --save_output	  (default false)
   --print_every      (default 10)
]]

if mp.server == 'pc' then
    mp.root = 'logs'
    mp.winsize = 20  -- total number of frames
    mp.num_past = 19 --10
    mp.num_future = 1 --10
	mp.dataset_folder = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/opdata/3'--dataset_files_subsampled_dense_np2' --'hoho'
    mp.traincfgs = '[:-2:2-:]'
    mp.testcfgs = '[:-2:2-:]'
	mp.batch_size = 80 --1
    mp.lrdecay = 0.95
	mp.seq_length = 10
	mp.num_threads = 1
    mp.plot = true
	mp.cuda = false
	mp.cunn = false
    mp.max_epochs = 50
else
	mp.winsize = 20  -- total number of frames
    mp.num_past = 1 -- total number of past frames
    mp.num_future = 1
	mp.dataset_folder = '/om/data/public/mbchang/physics-data/4'  -- TODO 1in1out
	mp.seq_length = 10
	mp.num_threads = 4
    mp.plot = false
	mp.cuda = true
	mp.cunn = true
end

mp.object_dim = 8.0  -- hardcoded  -- TODO: put this into dataloader objectdim
mp.input_dim = mp.object_dim*mp.num_past--mp.winsize/2  -- TODO 1in1out
mp.out_dim = mp.object_dim*mp.num_future--mp.winsize/2  -- TODO 1in1out
mp.savedir = mp.root .. '/' .. mp.name

if mp.seed then torch.manualSeed(123) end
if mp.shuffle == 'false' then mp.shuffle = false end
if mp.relative == 'false' then mp.relative = false end
if mp.rand_init_wts == 'false' then mp.rand_init_wts = false end
if mp.save_output == 'false' then mp.save_output = false end
if mp.plot == 'false' then mp.plot = false end
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
                              mp.batch_size,
                              mp.shuffle,
                              mp.cuda,
                              mp.relative,
                              mp.num_past,
                              mp.winsize}
    train_loader = D.create('trainset', D.convert2allconfigs(mp.traincfgs), unpack(data_loader_args))
    val_loader =  D.create('valset', D.convert2allconfigs(mp.testcfgs), unpack(data_loader_args))  -- using testcfgs
    test_loader = D.create('testset', D.convert2allconfigs(mp.testcfgs), unpack(data_loader_args))
    model = M.create(mp, preload, model_path)

    trainLogger = optim.Logger(paths.concat(mp.savedir ..'/', 'train.log'))
    experimentLogger = optim.Logger(paths.concat(mp.savedir ..'/', 'experiment.log'))
    if mp.plot == false then
        trainLogger.showPlot = false
        experimentLogger.showPlot = false
    end
    print("Initialized Network")
end

function inittest(preload, model_path)
    print("Network parameters:")
    print(mp)
    local data_loader_args = {mp.dataset_folder,
                              mp.batch_size,
                              mp.shuffle,
                              mp.cuda,
                              mp.relative,
                              mp.num_past,
                              mp.winsize}
    test_loader = D.create('testset', D.convert2allconfigs(mp.testcfgs), unpack(data_loader_args))  -- TODO: Testing on trainset
    model = M.create(mp, preload, model_path)
    modelfile = model_path
    print("Initialized Network")
end


-- closure: returns loss, grad_params
function feval_train(params_)  -- params_ should be first argument
    local this, context, y, mask = unpack(train_loader:next_batch())
    y = crop_future(y, {y:size(1), mp.winsize-mp.num_past, mp.object_dim}, {2,mp.num_future})
    local loss, state, predictions = model:fp(params_, {this=this,context=context}, y)
    -- print(predictions[torch.find(mask,1)[1]]:size())
    local grad = model:bp({this=this,context=context}, y, mask, state)
    collectgarbage()
    return loss, grad -- f(x), df/dx
end

-- tensor (batchsize, winsize*obj_dim)
-- reshapesize (batchsize, winsize, obj_dim)
-- cropdim (dim, amount_to_take) == (dim, mp.num_future)
function crop_future(tensor, reshapesize, cropdim)
    local crop = tensor:clone()
    crop = crop:reshape(unpack(reshapesize))
    --hacky
    if crop:dim() == 3 then
        assert(cropdim[1]==2)
        crop = crop[{{},{1,cropdim[2]},{}}]  -- (num_samples x num_future x 8) -- TODO the -1 should be a function of 1+num_future
        crop = crop:reshape(reshapesize[1], cropdim[2] * mp.object_dim)
    else
        assert(crop:dim()==4 and cropdim[1] == 3)
        crop = crop[{{},{},{1,cropdim[2]},{}}]
        crop = crop:reshape(reshapesize[1], mp.seq_length, cropdim[2] * mp.object_dim)
    end
    return crop
end

-- trains for one epoch
function train(epoch_num)
    local new_params, train_loss
    local loss_run_avg = 0
    for t = 1,train_loader.num_batches do
        -- xlua.progress(t, train_loader.num_batches)
        new_params, train_loss = optimizer(feval_train, model.theta.params, optim_state)  -- next batch
        assert(new_params == model.theta.params)
        if t % mp.print_every == 0 then
            print(string.format("epoch %2d\titeration %2d\tloss = %6.8f\tgradnorm = %6.4e",
                    epoch_num, t, train_loss[1], model.theta.grad_params:norm()))
        end

        loss_run_avg = loss_run_avg + train_loss[1]
        trainLogger:add{['log MSE loss (train set)'] =  torch.log(train_loss[1])}
        trainLogger:style{['log MSE loss (train set)'] = '~'}
        if mp.plot then trainLogger:plot() end
        if mp.cuda then cutorch.synchronize() end
        collectgarbage()
    end
    return loss_run_avg/train_loader.num_batches  -- because train_loss is returned as a table
    -- return train_loss[1]  -- because train_loss is returned as a table
end

-- test on dataset
function test(dataloader, params_, saveoutput)
    local sum_loss = 0
    for i = 1,dataloader.num_batches do
        if mp.server == 'pc ' then xlua.progress(i, dataloader.num_batches) end
        local this, context, y, mask, config, start, finish, context_future = unpack(dataloader:next_batch())
        y = crop_future(y, {y:size(1), mp.winsize-mp.num_past, mp.object_dim}, {2,mp.num_future})
        context_future = crop_future(context_future, {context_future:size(1), mp.seq_length, mp.winsize-mp.num_past, mp.object_dim}, {3,mp.num_future})
        local test_loss, state, predictions = model:fp(params_, {this=this,context=context}, y)
        sum_loss = sum_loss + test_loss

        -- here you have the option to save predictions into a file
        local prediction = predictions[torch.find(mask,1)[1]] -- (1, num_future)

        -- reshape to -- (num_samples x num_future x 8)
        prediction = prediction:reshape(this:size(1),
                                        mp.num_future,
                                        dataloader.object_dim)
        this = this:reshape(this:size(1),
                            mp.num_past,
                            dataloader.object_dim)
        y = y:reshape(y:size(1),
                            mp.num_future,
                            dataloader.object_dim)

        if mp.relative then
            prediction = prediction + this[{{},{-1}}]:expandAs(prediction)
            y = y + this[{{},{-1}}]:expandAs(y)
        end

        if saveoutput then
            save_example_prediction({this, context, y, prediction, context_future},
                                    {config, start, finish},
                                    modelfile,
                                    dataloader)
        end
    end
    local avg_loss = sum_loss/dataloader.num_batches
    collectgarbage()
    return avg_loss
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
-- function simulate(dataloader, params_, saveoutput)
--     -- TODO basically you have to assert that num_future here is 1
--     assert(dataloader.num_future == 1)
--     local sum_loss = 0
--     for i = 1,dataloader.num_batches do
--         if mp.server == 'pc ' then xlua.progress(i, dataloader.num_batches) end
--         -- TODO wait, do we want dataloader.num_future to be constrained to be 1 at this point?
--         local this, context, y, mask, config, start, finish, context_future = unpack(dataloader:next_batch())
--         local test_loss, state, predictions = model:fp(params_, {this=this,context=context}, y)
--         sum_loss = sum_loss + test_loss
--
--         -- here you have the option to save predictions into a file
--         local prediction = predictions[torch.find(mask,1)[1]] -- (1, num_future)
--
--         -- reshape to -- (num_samples x num_future x 8)
--         prediction = prediction:reshape(this:size(1),
--                                         mp.num_future,
--                                         dataloader.object_dim)
--
--
--         this = this:reshape(this:size(1),
--                             mp.num_past,
--                             dataloader.object_dim)
--
--         -- TODO: relative indexing convert back
--         if mp.relative then
--             prediction = prediction + this[{{},{-1}}]:expandAs(prediction)
--             y = y + this[{{},{-1}}]:expandAs(y)
--         end
--
--         if saveoutput then
--             save_example_prediction({this, context, y, prediction, context_future},
--                                     {config, start, finish},
--                                     modelfile,
--                                     dataloader)
--         end
--     end
--     local avg_loss = sum_loss/dataloader.num_batches
--     collectgarbage()
--     return avg_loss
-- end

function save_example_prediction(example, description, modelfile_, dataloader)
    --[[
        example: {this, context, y, prediction, context_future}
        description: {config, start, finish}
        modelfile_: like '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/logs/lalala/network.t7'

        will save to something like:
            logs/<experiment-name>/predictions/<config.h5>
    --]]

    --unpack
    local this, context, y, prediction, context_future = unpack(example)
    local config, start, finish = unpack(description)

    local subfolder = mp.savedir .. '/' .. 'predictions/'
    if not paths.dirp(subfolder) then paths.mkdir(subfolder) end
    local save_path = mp.savedir .. '/' .. 'predictions/' .. config..'_['..start..','..finish..'].h5'

    if mp.cuda then
        prediction = prediction:float()
        this = this:float()
        context = context:float()
        y = y:float()
        context_future = context_future:float()
    end

    -- For now, just save it as hdf5. You can feed it back in later if you'd like
    save_to_hdf5(save_path,
        {pred=prediction,
        this=this:reshape(this:size(1),
                    mp.num_past,
                    dataloader.object_dim),
        context=context:reshape(context:size(1),
                    context:size(2),
                    mp.num_past,
                    dataloader.object_dim),
        y=y:reshape(y:size(1),
                    mp.num_future,
                    dataloader.object_dim),
        context_future=context_future:reshape(context_future:size(1),
                    context_future:size(2),
                    mp.num_future,
                    dataloader.object_dim)})
end

-- runs experiment
function experiment()
    torch.setnumthreads(mp.num_threads)
    print('<torch> set nb of threads to ' .. torch.getnumthreads())
    for i = 1, mp.max_epochs do
        print('Learning rate is now '..optim_state.learningRate)
        checkpoint(mp.savedir .. '/network.t7', model.network, mp) -- model.rnns[1]?
        checkpoint(mp.savedir .. '/params.t7', model.theta.params, mp)
        print('Saved model')

        local train_loss
        train_loss = train(i)
        -- train_loss = test(train_test_loader)
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
        if mp.plot then experimentLogger:plot() end
        if mp.cuda then cutorch.synchronize() end

        -- here you can adjust the learning rate based on val loss
        optim_state.learningRate =optim_state.learningRate*mp.lrdecay
        collectgarbage()
    end
end

function checkpoint(savefile, data, mp_)
    if mp_.cuda then
        data = data:float()
        torch.save(savefile, data)
        data = data:cuda()
    else
        torch.save(savefile, data)
    end
    collectgarbage()
end

function run_experiment()
    inittrain(false)
    experiment()
end

function predict()
    inittest(true, mp.savedir ..'/'..'network.t7')
    print(test(test_loader, torch.load(mp.savedir..'/'..'params.t7'), true))
end

-- function curriculum()
--     local cur = cur = {'[:-1:1-:]','[:-2:2-:]','[:-3:3-:]',
--                         '[:-4:4-:]','[:-5:5-:]','[:-6:6-:]'}
--     for _,problem in cur do
--         mp.traincfgs = problem
--         mp.testcfgs = problem
--         print('traincfgs', mp.traincfgs)
--         print('testcfgs', mp.testcfgs)
--         reset folder to save
--         run_experiment()
--         -- make sure that things get reset correctly.
--     end
-- end

------------------------------------- Main -------------------------------------
if mp.mode == 'exp' then
    run_experiment()
else
    predict()
end
-- curriculum()
