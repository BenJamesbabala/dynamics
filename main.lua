-- Michael B Chang

-- Third Party Imports
require 'torch'
require 'nn'
require 'optim'
require 'image'
require 'xlua'
require 'Base'
require 'sys'
require 'pl'
torch.setdefaulttensortype('torch.FloatTensor')
require 'data_utils'
local tablex = require 'pl.tablex'

-- Local Imports
local model_utils = require 'model_utils'
-- local D = require 'data_sampler'
local D = require 'general_data_sampler'
local D2 = require 'datasaver'
require 'logging_utils'

config_args = require 'config'
local data_process = require 'data_process'

------------------------------------- Init -------------------------------------
local cmd = torch.CmdLine()
cmd:option('-mode', "exp", 'exp | pred | simulate | save')
cmd:option('-server', "op", 'pc = personal | op = openmind')
cmd:option('logs_root', 'logs', 'subdirectory to save logs and checkpoints')
cmd:option('data_root', '../data', 'subdirectory to save data')
cmd:option('-model', "ffobj", 'ff | ffobj | lstmobj | gruobj')
cmd:option('-name', "mj", 'experiment name')
cmd:option('-seed', true, 'manual seed or not')

-- dataset
cmd:option('-dataset_folders', '', 'dataset folder')
cmd:option('-test_dataset_folders', '', 'dataset folder')

-- model params
cmd:option('-rnn_dim', 50, 'hidden dimension')
-- cmd:option('-object_dim', 9, 'number of input features')
cmd:option('-layers', 3, 'layers in network')
cmd:option('-relative', true, 'relative state vs absolute state')
cmd:option('-diff', false, 'use relative context position and velocity state')
cmd:option('-accel', false, 'use acceleration data')

-- training options
cmd:option('-opt', "rmsprop", 'rmsprop | adam')
cmd:option('-batch_size', 50, 'batch size')
cmd:option('-shuffle', false, 'shuffle batches')
cmd:option('-max_iter', 100000, 'max number of iterations')
cmd:option('-L2', 0, 'L2 regularization')  -- 0.001
cmd:option('-lr', 0.0003, 'learning rate')
cmd:option('-lrdecay', 0.99, 'learning rate annealing')

-- priority sampling
cmd:option('-ps', true, 'turn on priority sampling')
cmd:option('-sharpen', 1, 'sharpen exponent')

-- experiment options
cmd:option('-plot', false, 'turn on/off plot')

-- every options
cmd:option('-print_every', 100, 'print every number of batches')
cmd:option('-save_every', 10000, 'save every number of batches')
cmd:option('-val_every',10000,'val every number of batches')
cmd:option('-lrdecay_every',2000,'decay lr every number of batches')
cmd:option('-lrdecayafter', 50000, 'number of epochs before turning down lr')

cmd:text()

-- parse input params
mp = cmd:parse(arg)

if mp.server == 'pc' then
    mp.data_root = 'mj_data'
    mp.logs_root = 'logs'
    mp.winsize = 10 -- total number of frames
    mp.num_past = 2 --10
    mp.num_future = 1 --10
	mp.batch_size = 5 --1
    mp.max_iter = 10000
    -- mp.lrdecay = 0.99
	mp.seq_length = 10
	mp.num_threads = 1
    mp.print_every = 10
    mp.save_every = 50
    mp.val_every = 50
    mp.plot = false--true
	mp.cuda = false
else
	mp.winsize = 10  -- total number of frames
    mp.num_past = 2 -- total number of past frames
    mp.num_future = 1
	mp.seq_length = 10
	mp.num_threads = 4
	mp.cuda = true
end

local M

if mp.model == 'lstmobj' or mp.model == 'ffobj' or mp.model == 'gruobj' then
    M = require 'variable_obj_model'
elseif mp.model == 'lstmtime' then
    M = require 'lstm_model'
elseif mp.model == 'ff' then
    M = require 'feed_forward_model'
else
    error('Unrecognized model')
end

mp.object_dim = config_args.si.oid-- TODO! make this more versatile! (don't hardcode it to oid)
mp.input_dim = mp.object_dim*mp.num_past
mp.out_dim = mp.object_dim*mp.num_future
mp.name = string.gsub(string.gsub(string.gsub(mp.name,'{',''),'}',''),"'",'')
mp.savedir = mp.logs_root .. '/' .. mp.name
print(mp.savedir)

if mp.seed then torch.manualSeed(123) end
if mp.cuda then
    require 'cutorch'
    require 'cunn'
end

local optimizer, optim_state
if mp.opt == 'rmsprop' then
    optimizer = optim.rmsprop
    optim_state = {learningRate   = mp.lr}
elseif mp.opt == 'adam' then
    optimizer = optim.adam
    optim_state = {learningRate   = mp.lr}
else
    error('unknown optimizer')
end

mp.dataset_folders = assert(loadstring("return "..string.gsub(mp.dataset_folders,'\"',''))())
mp.test_dataset_folders = assert(loadstring("return "..string.gsub(mp.test_dataset_folders,'\"',''))())

local model, train_loader, test_loader, modelfile
local train_losses, val_losses, test_losses = {},{},{}


------------------------------- Helper Functions -------------------------------

-- initialize
function inittrain(preload, model_path)
    print("Network parameters:")
    print(mp)
    local data_loader_args = {data_root=mp.data_root..'/',
                              dataset_folders=mp.dataset_folders,
                              maxwinsize=config_args.maxwinsize,
                              winsize=mp.winsize, -- not sure if this should be in mp
                              num_past=mp.num_past,
                              num_future=mp.num_future,
                              relative=mp.relative,
                              sim=false,
                              cuda=mp.cuda
                            }
    -- test_args is the same but with a different dataset_folder
    local test_args = tablex.deepcopy(data_loader_args)
    test_args.dataset_folders = mp.test_dataset_folders

    train_loader = D.create('trainset', tablex.deepcopy(data_loader_args))
    val_loader =  D.create('valset', tablex.deepcopy(data_loader_args))  -- using testcfgs
    test_loader = D.create('testset', tablex.deepcopy(test_args))
    train_test_loader = D.create('trainset', tablex.deepcopy(data_loader_args))
    model = M.create(mp, preload, model_path)
    print(model.network)

    trainLogger = optim.Logger(paths.concat(mp.savedir ..'/', 'train.log'))
    experimentLogger = optim.Logger(paths.concat(mp.savedir ..'/', 'experiment.log'))
    if mp.plot == false then
        trainLogger.showPlot = false
        experimentLogger.showPlot = false
    end

    -- save args
    torch.save(mp.savedir..'/args.t7', {mp=mp,config_args=config_args})
    print("Initialized Network")
end

function initsavebatches()
    mp.cuda = false
    mp.cunn = false
    mp.shuffle = false
    config_args.batch_size = mp.batch_size
    for _, dataset_folder in pairs(mp.dataset_folders) do
        local data_folder = mp.data_root..'/'..dataset_folder..'/batches'
        if not paths.dirp(data_folder) then
            local jsonfolder = mp.data_root..'/'..dataset_folder..'/jsons'--..'/'..mp.dataset_folder..'.json' -- REDO!
            local outfolder = mp.data_root..'/'..dataset_folder..'/batches'  -- TODO: make this some global thing!
            print('Saving batches of size '..mp.batch_size..' from '..jsonfolder..'into '..outfolder)
            local dp = data_process.create(jsonfolder, outfolder, config_args)
            dp:create_datasets_batches()
        else
            print('Batches for '..dataset_folder..' already made')
        end
    end
end

-- closure: returns loss, grad_params
function feval_train(params_)  -- params_ should be first argument

    local batch = train_loader:sample_priority_batch(mp.sharpen)
    local loss, prediction = model:fp(params_, batch)
    local grad = model:bp(batch,prediction)

    -- L2 stuff

    if mp.L2 > 0 then
        -- Loss:
        loss = loss + mp.L2 * model.theta.params:norm(2)^2/2
        -- Gradients:
        model.theta.grad_params:add(model.theta.params:clone():mul(mp.L2) )
    end

    train_loader:update_batch_weight(loss)
    collectgarbage()
    return loss, grad -- f(x), df/dx
end

function train(start_iter, epoch_num)
    local epoch_num = epoch_num or 1
    local start_iter = start_iter or 1
    print('Start iter:', start_iter)
    print('Start epoch num:', epoch_num)
    for t = start_iter,mp.max_iter do

        local new_params, train_loss = optimizer(feval_train,
                                model.theta.params, optim_state)  -- next batch

        assert(new_params == model.theta.params)

        trainLogger:add{['log MSE loss (train set)'] = torch.log(train_loss[1])}
        trainLogger:style{['log MSE loss (train set)'] = '~'}

        -- print
        if (t-start_iter+1) % mp.print_every == 0 then
            print(string.format("epoch %2d  iteration %2d  loss = %6.8f"..
                            "  gradnorm = %6.4e  batch = %d-%d    "..
                            "hardest batch: %d-%d    with loss %6.8f lr = %6.4e",
                    epoch_num, t, train_loss[1],
                    model.theta.grad_params:norm(),
                    train_loader.current_dataset,
                    train_loader.current_sampled_id,
                    train_loader:get_hardest_batch()[3],
                    train_loader:get_hardest_batch()[2],
                    train_loader:get_hardest_batch()[1],
                    optim_state.learningRate))
        end

        -- validate
        if (t-start_iter+1) % mp.val_every == 0 then
            v_train_loss, v_val_loss, v_tets_loss = validate()
            train_losses[#train_losses+1] = v_train_loss
            val_losses[#val_losses+1] = v_val_loss
            test_losses[#test_losses+1] = v_test_loss
            assert(mp.save_every % mp.val_every == 0 or
                    mp.val_every % mp.save_every == 0)

            -- save
            if (t-start_iter+1) % mp.save_every == 0 then
                local model_file = string.format('%s/epoch%.2f_%.4f.t7',
                                            mp.savedir, epoch_num, v_val_loss)
                print('saving checkpoint to ' .. model_file)
                model.network:clearState()

                local checkpoint = {}
                checkpoint.model = model  -- TODO: should I save the model.theta?
                checkpoint.mp = mp
                checkpoint.train_losses = train_losses
                checkpoint.val_losses = val_losses
                checkpoint.test_losses = test_losses
                checkpoint.iters = t
                torch.save(model_file, checkpoint)
                print('Saved model')
            end
        end

        -- lr decay
        -- here you can adjust the learning rate based on val loss
        if t >= mp.lrdecayafter and (t-start_iter+1) % mp.lrdecay_every == 0 then
            optim_state.learningRate =optim_state.learningRate*mp.lrdecay
            print('Learning rate is now '..optim_state.learningRate)
        end

        if (t-start_iter+1) % train_loader.num_batches == 0 then
            epoch_num = t / train_loader.num_batches + 1
        end

        if mp.plot then trainLogger:plot() end
        if mp.cuda then cutorch.synchronize() end
        collectgarbage()
    end
end

function test(dataloader, params_, saveoutput)
    local sum_loss = 0
    for i = 1,dataloader.num_batches do
        if mp.server == 'pc ' then xlua.progress(i, dataloader.num_batches) end

        local batch = dataloader:sample_sequential_batch()

        local test_loss, prediction = model:fp(params_, batch)

        -- hacky for backwards compatability
        local this, context, y, context_future, mask = unpack(batch)

        context = context:reshape(context:size(1), context:size(2),
                                    mp.num_past, mp.object_dim)

        -- reshape to -- (num_samples x num_future x 8)
        prediction = prediction:reshape(
                                mp.batch_size, mp.num_future, mp.object_dim)   -- TODO RESIZE THIS
        this = this:reshape(mp.batch_size, mp.num_past, mp.object_dim)   -- TODO RESIZE THIS

        -- take care of relative position
        if mp.relative then
            prediction = data_process.relative_pair(prediction, this, true)
            y = data_process.relative_pair(y, this, true)
        end

        -- save
        if saveoutput then
            save_ex_pred({this, context, y, prediction, context_future},
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


function save_ex_pred(example, description, modelfile_, dataloader, numsteps)
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
    local save_path = subfolder .. config..'_['..start..','..finish..'].h5'

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

function validate()
    local train_loss = test(train_test_loader, model.theta.params, false)
    local val_loss = test(val_loader, model.theta.params, false)
    local test_loss = test(test_loader, model.theta.params, false)
    print('train loss\t'..train_loss..
            '\tval loss\t'..val_loss..'\ttest_loss\t'..test_loss)

    -- Save logs
    experimentLogger:add{['log MSE loss (train set)'] =  torch.log(train_loss),
                         ['log MSE loss (val set)'] =  torch.log(val_loss),
                         ['log MSE loss (test set)'] =  torch.log(test_loss)}
    experimentLogger:style{['log MSE loss (train set)'] = '~',
                           ['log MSE loss (val set)'] = '~',
                           ['log MSE loss (test set)'] = '~'}
   if mp.plot then experimentLogger:plot() end
    return train_loss, val_loss, test_loss
end

-- runs experiment
function experiment(start_iter, epoch_num)
    torch.setnumthreads(mp.num_threads)
    print('<torch> set nb of threads to ' .. torch.getnumthreads())
    train(start_iter, epoch_num)
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


-- UPDATE
function run_experiment_load()
    local snapshot = getLastSnapshot(mp.name)
    print(snapshot)
    local checkpoint = torch.load(mp.savedir ..'/'..snapshot)
    mp = checkpoint.mp  -- completely overwrite
    inittrain(true, mp.savedir ..'/'..snapshot)  -- assuming the mp.savedir doesn't change

    -- These are things you have to set; although priority sampler might not be reset
    local iters = mp.val_every * #checkpoint.val_losses + 1
    -- local epoch_num = math.floor(iters / train_loader.num_batches) + 1
    local epoch_num = 1

    mp.lr = 1.077384359378e-05
    optim_state = {learningRate   = mp.lr}

    experiment(iters, epoch_num)
end

function getLastSnapshot(network_name)
    local res_file = io.popen("ls -t "..mp.logs_root..'/'..network_name..
                        " | grep -i epoch | head -n 1")
    local status, result = pcall(function()
        return res_file:read():match( "^%s*(.-)%s*$" ) end)
    print(result)
    res_file:close()
    if not status then return false else return result end
end

------------------------------------- Main -------------------------------------
if mp.mode == 'exp' then
    initsavebatches()
    print('Running experiment.')
    run_experiment()
elseif mp.mode == 'expload' then
    run_experiment_load()
elseif mp.mode == 'save' then
    initsavebatches()
else
    error('unknown mode')
end
