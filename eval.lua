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
require 'torchx'
-- require 'hdf5'
torch.setdefaulttensortype('torch.FloatTensor')
require 'data_utils'
local tablex = require 'pl.tablex'
local pls = require 'pl.stringx'

require 'rnn'  -- also installs moses (https://github.com/Yonaba/Moses/blob/master/doc/tutorial.md), like underscore.js
require 'torch'
require 'nngraph'
require 'Base'
require 'IdentityCriterion'
require 'gnuplot'

-- Local Imports
local model_utils = require 'model_utils'
local D = require 'general_data_sampler'
local D2 = require 'datasaver'
require 'logging_utils'
require 'json_interface'

local data_process = require 'data_process'

------------------------------------- Init -------------------------------------
local cmd = torch.CmdLine()
cmd:option('-mode', "exp", 'exp | pred | simulate | save')
cmd:option('-server', "op", 'pc = personal | op = openmind')
cmd:option('logs_root', 'logs', 'subdirectory to save logs and checkpoints')
cmd:option('data_root', '../data', 'subdirectory to save data')
cmd:option('-name', "mj", 'experiment name')
cmd:option('-seed', true, 'manual seed or not')
-- dataset
cmd:option('-test_dataset_folders', '', 'dataset folder')
-- experiment options
cmd:option('-ns', 3, 'number of test batches')
cmd:option('-steps', 58, 'steps to simulate')
cmd:text()

-- parse input params
mp = cmd:parse(arg)

if mp.server == 'pc' then
    mp.data_root = 'mj_data'    
    mp.logs_root = 'logs'
    mp.winsize = 3 -- total number of frames
    mp.num_past = 2 --10
    mp.num_future = 1 --10
	mp.batch_size = 5 --1
	-- mp.seq_length = 10
	mp.num_threads = 1
	mp.cuda = false
else
	mp.winsize = 3  -- total number of frames
    mp.num_past = 2 -- total number of past frames
    mp.num_future = 1
	-- mp.seq_length = 10
	mp.num_threads = 4
	mp.cuda = false
end

local M

-- world constants
local subsamp = 1


mp.name = string.gsub(string.gsub(string.gsub(mp.name,'{',''),'}',''),"'",'')
mp.test_dataset_folders = assert(loadstring("return "..string.gsub(mp.test_dataset_folders,'\"',''))())
mp.savedir = mp.logs_root .. '/' .. mp.name
mp.relative=true -- TODO_lowpriority: address this!

if mp.seed then torch.manualSeed(123) end
if mp.cuda then
    require 'cutorch'
    require 'cunn'
end

local model, test_loader, modelfile, dp

------------------------------- Helper Functions -------------------------------

function inittest(preload, model_path, opt)
    dp = data_process.create(model_path, model_path, config_args)  -- jsonfile and outfile are unpopopulated!  Let's just fill them with the model_path?
    model = M.create(mp, preload, model_path)
    mp.cuda = false -- NOTE HACKY

    if not(string.find(mp.savedir, 'tower') == nil) then
        assert((string.find(mp.savedir, 'ball') == nil) and 
               (string.find(mp.savedir, 'mixed') == nil) and 
               (string.find(mp.savedir, 'invisible') == nil))
        config_args.maxwinsize = config_args.maxwinsize_long
    else
        config_args.maxwinsize = config_args.maxwinsize
    end

    local data_loader_args = {data_root=mp.data_root..'/',
                              dataset_folders=mp.test_dataset_folders,
                              maxwinsize=config_args.maxwinsize,
                              winsize=mp.winsize, -- not sure if this should be in mp
                              num_past=mp.num_past,
                              num_future=mp.num_future,
                              relative=mp.relative,
                              subdivide=opt.subdivide,
                              shuffle=config_args.shuffle,
                              sim=opt.sim,
                              cuda=mp.cuda
                            }
    test_loader = D.create('testset', tablex.deepcopy(data_loader_args))

    modelfile = model_path
    print("Network parameters:")
    print(mp)
    print(model.network)
end

-- function backprop2input()
--     -- for one input

--     -- get batch
--     local batch = test_loader:sample_sequential_batch()  -- TODO replace with some other data loader!
--     local this, context, y, mask = unpack(batch)
--     local x = {this=this,context=context}

--     if not sim then
--         y = crop_future(y, {y:size(1), mp.winsize-mp.num_past, mp.object_dim},
--                             {2,mp.num_future})
--     end
--     -- convert_type

--     -- unpack inputs
--     local this_past     = convert_type(x.this:clone(), mp.cuda)
--     local context       = convert_type(x.context:clone(), mp.cuda)
--     local this_future   = convert_type(y:clone(), mp.cuda)

--     function feval_back2mass(inp)
--         -- inp is this_past
--         -- forward
--         local splitter = split_output(mp)
--         local preproc = preprocess_input(mask)
--         if mp.cuda then preproc:cuda() end
--         local input = preproc:forward{inp,context}  -- this changes, context doesn't
--         if torch.find(mask,1)[1] == 1 then input = {input} end

--         local prediction = model.network:forward(input)
--         local p_pos, p_vel, p_obj_prop = unpack(splitter:forward(prediction))
--         local gt_pos, gt_vel, gt_obj_prop =
--                             unpack(split_output(mp):forward(this_future))
--         local loss = model.criterion:forward(p_vel, gt_vel)

--         -- backward
--         local d_pos = model.identitycriterion:backward(p_pos, gt_pos)
--         local d_vel = model.criterion:backward(p_vel, gt_vel)
--         local d_obj_prop = model.identitycriterion:backward(p_obj_prop,
--                                                             gt_obj_prop)
--         local d_pred = splitter:backward({prediction},
--                                         {d_pos, d_vel, d_obj_prop})

--         local g_input = model.network:backward(input, d_pred)
--         if torch.find(mask,1)[1] == 1 then g_input = g_input[1] end
--         preproc:updateGradInput(inp, g_input)

--         collectgarbage()
--         return loss, preproc.gradInput[1]  -- this should have been updated
--     end

--     local b2i_optstate = {learningRate = 0.01}

--     -- infer the masses of ALL THE BALLS (or just you?)
--     -- for now let's just infer the mass of you

--     -- or should I preface the network with a wrapper that selects the input, because rmsprop expects a tensor!

--     -- perturb
--     -- this_past:resize(mp.batch_size, mp.num_past, mp.object_dim)
--     -- this_past[{{},{},{5}}]:fill(1)
--     -- this_past[{{},{},{6,8}}]:fill(0)
--     -- this_past:resize(mp.batch_size, mp.num_past*mp.object_dim)

--     print('initial input')
--     print(this_past[{{1},{1,9}}])
--     t = 1
--     while t <= 100 do
--         local old_this = this_past:clone()

--         -- pass in input to rmsprop: automatically modifies this_past
--         local _, loss = optim.rmsprop(feval_back2mass, this_past, b2i_optstate)  -- not getting updates! (or implicilty updated)

--         -- modify only the mass
--         old_this:resize(mp.batch_size, mp.num_past, mp.object_dim)
--         this_past:resize(mp.batch_size, mp.num_past, mp.object_dim)

--         -- [{{5,8}}] is the one-hot mass
--         this_past[{{},{},{1,4}}] = old_this[{{},{},{1,4}}]
--         this_past[{{},{},{9}}] = old_this[{{},{},{9}}]

--         this_past:resize(mp.batch_size, mp.num_past*mp.object_dim)

--         if t % 10 == 0 then
--             b2i_optstate.learningRate = b2i_optstate.learningRate * 0.99
--         end

--         if t % 10 == 0 then
--             print(this_past[{{1},{1,9}}])
--         end

--         if t % 10 == 0 then
--             print(loss[1])
--         end
--         -- if (this_past-target_input):norm() < 1e-5 then
--         --     break
--         -- end
--         t = t + 1
--     end
--     print ('final input after '..t..' iterations')
--     print(this_past[{{1},{1,9}}])
-- end

local function simulate_all_preprocess(past, future, j, t, num_particles)
    -- construct batch
    local this = torch.squeeze(past[{{},{j}}])  -- no flag yet

    local y = future[{{},{j},{t}}]  -- no flag yet
    y = torch.squeeze(y,2)  -- no flag good up to here

    -- print('orig y')
    -- print(torch.squeeze(y,2))
    -- assert(false)
    local y_before_relative = y:clone()

    if mp.relative then
        y = data_process.relative_pair(this, y, false)  -- absolute to relative
    end

    local context, context_future
    if j == 1 then
        context = past[{{},{j+1,-1}}]
        context_future = future[{{},{j+1,-1},{t}}]
    elseif j == num_particles then
        context = past[{{},{1,-2}}]
        context_future = future[{{},{1,-2},{t}}]
    else
        context = torch.cat({past[{{},{1,j-1}}], past[{{},{j+1,-1}}]},2)
        context_future = torch.cat({future[{{},{1,j-1},{t}}], future[{{},{j+1,-1},{t}}]},2)
    end

    return this, y, context, context_future, y_before_relative
end

local function simulate_all_postprocess(pred, this, raw_obj_dim)
    -- HERE chop off the last part in pred
    if mp.of then pred = pred[{{},{1,-2}}] end

    pred = pred:reshape(mp.batch_size, mp.num_future, raw_obj_dim)

    -- relative coords for next timestep
    if mp.relative then
        pred = data_process.relative_pair(this, pred, true)  -- relative to absolute
    end

    -- restore object properties because we aren't learning them
    pred[{{},{},{config_args.ossi,-1}}] = this[{{},{-1},{config_args.ossi,-1}}]

    -- update position
    pred = model:update_position(this, pred)

    -- update angle
    pred = model:update_angle(this, pred)

    -- if object is ball, then angle and angular velocity are 0
    if pred[{{},{},config_args.si.oid[1]}]:equal(convert_type(torch.ones(mp.batch_size,1), mp.cuda)) then
        pred[{{},{},{config_args.si.a,config_args.si.av}}]:zero()
    end

    pred = unsqueeze(pred, 2)
    return pred
end

-- invalid_focus_mask: 1 means invalid, 0 valid
-- good
function make_invalid_dummy(this, invalid_focus_mask)
    local this = this:clone()
    assert(invalid_focus_mask:sum() > 0)

    -- first we find a valid focus object. that will be our dummy.
    -- we find a zero element
    local dummy_idx = torch.find(invalid_focus_mask,0)[1]
    local dummy_focus = this[{{dummy_idx},{},{}}]:clone() -- good

    -- then, for all invalid focus object, we will replace it with the dummy
    local invalid_idxs = torch.find(invalid_focus_mask,1)
    -- print(invalid_idxs)
    for _,invalid_idx in pairs(invalid_idxs) do
        this[{{invalid_idx},{},{}}] = dummy_focus:clone()
    end

    return this
end 


function replace_invalid_dummy(pred, y_before_relative, this, invalid_focus_mask)
    local pred = pred:clone()
    local y_before_relative = y_before_relative:clone()
    local this = this:clone()
    assert(invalid_focus_mask:sum() > 0)

    -- print(torch.squeeze(y))
    -- assert(false)

    -- -- first change y back to absolute
    -- print('y in replace_invalid_dummy')
    -- print(torch.squeeze(y_before_relative))
    -- assert(false)

    -- next we will take 
    local invalid_idxs = torch.find(invalid_focus_mask,1)
    for _,invalid_idx in pairs(invalid_idxs) do
        pred[{{invalid_idx},{},{}}] = y_before_relative[{{invalid_idx},{},{}}]:clone() -- replace with ground truth
    end

    -- wait, note that you still need ground truth in order to compute your prediction score. so it is okay
    -- to predict against a ground truth here.

    return pred  
end


function simulate_all(dataloader, params_, saveoutput, numsteps, gt)
    -- local count = 0
    local losses_through_time_all_batches = torch.zeros(dataloader.total_batches, numsteps)
    local mag_error_through_time_all_batches = torch.zeros(dataloader.total_batches, numsteps)
    local ang_error_through_time_all_batches = torch.zeros(dataloader.total_batches, numsteps)
    local vel_loss_through_time_all_batches = torch.zeros(dataloader.total_batches, numsteps)
    local ang_vel_loss_through_time_all_batches = torch.zeros(dataloader.total_batches, numsteps)

    local experiment_name = paths.basename(dataloader.dataset_folder)
    local subfolder = mp.savedir .. '/' .. experiment_name .. '_predictions/'
    if not paths.dirp(subfolder) then paths.mkdir(subfolder) end

    local logfile = 'gt_divergence.log'
    local gtdivergenceLogger = optim.Logger(paths.concat(subfolder, logfile))  -- this should be dataloader specific!
    gtdivergenceLogger.showPlot = false
    -- I have to averge through all batches

    assert(numsteps <= dataloader.maxwinsize-mp.num_past,
            'Number of predictive steps should be less than '..
            dataloader.maxwinsize-mp.num_past+1)
    for i = 1, dataloader.total_batches do

        if mp.server == 'pc' then xlua.progress(i, dataloader.total_batches) end

        -- local batch, current_dataset = dataloader:sample_sequential_batch(false)
        local batch = dataloader:sample_sequential_batch()

        -- get data
        local this_orig, context_orig, y_orig, context_future_orig, mask = unpack(batch)  -- no flag yet

        -- print('this')
        -- print(torch.squeeze(this_orig[{{},{1},{}}]))
        -- print('y')
        -- print(torch.squeeze(y_orig[{{},{1},{}}]))
        -- assert(false)

        local raw_obj_dim = this_orig:size(3)

        -- crop to number of timestesp
        y_orig = y_orig[{{},{1, numsteps}}]   -- no flag yet
        context_future_orig = context_future_orig[{{},{},{1, numsteps}}]   -- no flag yet

        local num_particles = torch.find(mask,1)[1] + 1

        -- arbitrary notion of ordering here
        -- past: (bsize, num_particles, mp.numpast*mp.objdim)
        -- -- future: (bsize, num_particles, (mp.winsize-mp.numpast), mp.objdim)
        local past = torch.cat({unsqueeze(this_orig:clone(),2), context_orig},2)   -- no flag yet
        local future = torch.cat({unsqueeze(y_orig:clone(),2), context_future_orig},2)  -- good   -- no flag yet (because we don't know which is focus or context)

        assert(past:size(2) == num_particles and future:size(2) == num_particles)

        local pred_sim = model_utils.transfer_data(
                            torch.zeros(mp.batch_size, num_particles,
                                        numsteps, y_orig:size(3)),   -- the dimensionality here inludes a flag; this may be a problem?
                            mp.cuda)

        -- loop through time
        for t = 1, numsteps do
            if mp.server == 'pc' then xlua.progress(t, numsteps) end

            -- for each particle, update to the next timestep, given
            -- the past configuration of everybody
            -- total_particles = total_particles+num_particles

            -- it makes no sense to accumulate
            local loss_within_batch = 0
            local mag_error_within_batch = 0
            local ang_error_within_batch = 0
            local vel_loss_within_batch = 0
            local ang_vel_loss_within_batch = 0
            local counter_within_batch = 0

            for j = 1, num_particles do

                -- here you should create a mask

                -- select indices of focus and context


                -- switch to a new focus object
                local this, y, context, context_future, y_before_relative = simulate_all_preprocess(past, future, j, t, num_particles)


                -- Ok, note that you only want the examples where this is a ball or block
                -- these templates are (bsize, oid_dim)
                local oid_onehot, template_ball, template_block, template_obstacle = get_oid_templates(this, config_args, mp.cuda)
                local num_oids = config_args.si.oid[2]-config_args.si.oid[1]+1
                local invalid_focus_mask = oid_onehot:eq(template_obstacle):sum(2):eq(num_oids)  -- 1 if invalid
                -- print(invalid_focus_mask)
                -- assert(false)
                -- print(invalid_focus_mask:sum())
                -- print(#invalid_focus_mask)
                -- assert(false)
                if invalid_focus_mask:sum() < invalid_focus_mask:size(1) then

                    -- print(invalid_focus_mask)
                    -- assert(false)
                    -- note that we have to keep the batch size constant.
                    -- okay, so I think we'd need to do some dummy filling.
                    -- for the ones that have an obstacle, I just need to fill it with a dummy entry
                    -- then after I predict, I replace it with its corresponding entry in future, but remember to apply relative pair. 
                    -- to check, make sure that the context obstacles just never move.

                    -- if we have some entries where obstacle is this
                    if invalid_focus_mask:sum() > 0 then
                        -- for the ones that have an obstacle, I just need to fill it with a dummy entry
                        -- print('this before')
                        -- print(torch.squeeze(this[{{},{-1}}],2))
                        this = make_invalid_dummy(this, invalid_focus_mask:clone())
                        -- print('this after')
                        -- print(torch.squeeze(this[{{},{-1}}],2))
                        -- assert(false)
                    end -- good

                    -- construct batch
                    local batch = {this, context, y, _, mask}  -- you need context_future to be in here!

                    -- print('y after batch')
                    -- print(torch.squeeze(y))

                    -- evaluate
                    local loss, pred, vel_loss, ang_vel_loss = model:fp(params_,batch,true)
                    local angle_error, relative_magnitude_error = angle_magnitude(pred, batch)  -- anything we need to do here?
                    -- count = count + 1

                    -- record
                    loss_within_batch = loss_within_batch + loss
                    ang_error_within_batch = ang_error_within_batch + angle_error
                    mag_error_within_batch = mag_error_within_batch + relative_magnitude_error
                    vel_loss_within_batch = vel_loss_within_batch + vel_loss
                    ang_vel_loss_within_batch = ang_vel_loss_within_batch + ang_vel_loss

                    -- counter_within_batch = counter_within_batch + 1  -- actually this should be the fraction of valid examples
                    -- print((1-invalid_focus_mask):sum())
                    -- print((1-invalid_focus_mask):sum())
                    -- print(invalid_focus_mask:size(1))
                    -- print(num_particles)
                    -- assert(false)
                    -- TODO: still needs more work
                    -- print((1-invalid_focus_mask):sum())
                    -- print(invalid_focus_mask)
                    counter_within_batch = counter_within_batch + (1-invalid_focus_mask):sum()/invalid_focus_mask:size(1) -- actually this should be the fraction of valid examples


                    -- update non-predictive parts of pred
                    pred = simulate_all_postprocess(pred, this, raw_obj_dim)

                    -- here you should apply the mask (such that by the end of it pred_sim will look valid)
                    if invalid_focus_mask:sum() > 0 then

                        -- print('pred before')
                        -- print(torch.squeeze(torch.squeeze(pred,2),2))

                        -- relative y
                        pred = replace_invalid_dummy(pred, y_before_relative, this, invalid_focus_mask:clone()) -- good

                        -- print('pred after')
                        -- print(torch.squeeze(torch.squeeze(pred,2),2))

                        -- assert(false)
                    end

                    -- write into pred_sim
                    pred_sim[{{},{j},{t},{}}] = pred

                else
                    -- TODO test this
                    print('#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#>#')
                    print('invalid_focus_mask:sum() = invalid_focus_mask:size(1)')
                    -- print(invalid_focus_mask)
                    pred_sim[{{},{j},{t},{}}] = y_before_relative
                end
            end

            -- update past for next timestep
            if mp.num_past > 1 then
                past = torch.cat({past[{{},{},{2,-1},{}}], pred_sim[{{},{},{t},{}}]}, 3)
            else
                assert(mp.num_past == 1)
                past = pred_sim[{{},{},{t},{}}]:clone()
            end

            -- record
            -- losses_through_time_all_batches[{{i},{t}}] = loss_within_batch/num_particles
            -- ang_error_through_time_all_batches[{{i},{t}}] = ang_error_within_batch/num_particles
            -- mag_error_through_time_all_batches[{{i},{t}}] = mag_error_within_batch/num_particles
            -- vel_loss_through_time_all_batches[{{i},{t}}] = vel_loss_within_batch/num_particles
            -- ang_vel_loss_through_time_all_batches[{{i},{t}}] = ang_vel_loss_within_batch/num_particles

            print(counter_within_batch)

            losses_through_time_all_batches[{{i},{t}}] = loss_within_batch/counter_within_batch
            ang_error_through_time_all_batches[{{i},{t}}] = ang_error_within_batch/counter_within_batch
            mag_error_through_time_all_batches[{{i},{t}}] = mag_error_within_batch/counter_within_batch
            vel_loss_through_time_all_batches[{{i},{t}}] = vel_loss_within_batch/counter_within_batch
            ang_vel_loss_through_time_all_batches[{{i},{t}}] = ang_vel_loss_within_batch/counter_within_batch
        end
        --- to be honest I don't think we need to break into past and context
        -- future, but actually that might be good for coloriing past and future, but
        -- actually I don't think so. For now let's just adapt it

        -- at this point, pred_sim should be all filled out
        -- break pred_sim into this and context_future
        -- recall: pred_sim: (batch_size,seq_length+1,numsteps,object_dim)
        -- recall that you had defined this_pred as the first obj in the future tensor
        local this_pred = torch.squeeze(pred_sim[{{},{1}}])
        if numsteps == 1 then this_pred = unsqueeze(this_pred,2) end

        local context_pred = pred_sim[{{},{2,-1}}]

        if mp.relative then
            y_orig = data_process.relative_pair(this_orig, y_orig, true)
        end

        if saveoutput and i <= mp.ns then
            save_ex_pred_json({this_orig, context_orig,
                                y_orig, context_future_orig,
                                this_pred, context_pred},
                                -- 'batch'..test_loader.datasamplers[current_dataset].current_sampled_id..'.json',
                                'batch'..dataloader.current_sampled_id..'.json',
                                experiment_name,
                                subfolder)
                                -- current_dataset)
        end
        collectgarbage()
    end

    -- average over all the batches
    local averaged_losses_through_time_all_batches = torch.totable(torch.squeeze(losses_through_time_all_batches:mean(1)))
    local averaged_ang_error_through_time_all_batches = torch.totable(torch.squeeze(ang_error_through_time_all_batches:mean(1)))
    local averaged_mag_error_through_time_all_batches = torch.totable(torch.squeeze(mag_error_through_time_all_batches:mean(1)))
    local averaged_vel_loss_through_time_all_batches = torch.totable(torch.squeeze(vel_loss_through_time_all_batches:mean(1)))
    local averaged_ang_vel_loss_through_time_all_batches = torch.totable(torch.squeeze(ang_vel_loss_through_time_all_batches:mean(1)))

    print(averaged_losses_through_time_all_batches)
    print(averaged_ang_error_through_time_all_batches)
    print(averaged_mag_error_through_time_all_batches)
    print(averaged_vel_loss_through_time_all_batches)
    print(averaged_ang_vel_loss_through_time_all_batches)

    for tt=1,#averaged_losses_through_time_all_batches do
        print(averaged_losses_through_time_all_batches[tt])
        gtdivergenceLogger:add{['Timesteps'] = tt, 
                                ['MSE Error'] = averaged_losses_through_time_all_batches[tt],
                                ['Cosine Difference'] = averaged_ang_error_through_time_all_batches[tt],
                                ['Magnitude Difference'] = averaged_mag_error_through_time_all_batches[tt],
                                ['Velocity Error'] = averaged_vel_loss_through_time_all_batches[tt],
                                ['Angular Velocity Error'] = averaged_ang_vel_loss_through_time_all_batches[tt]
                            }
        gtdivergenceLogger:style{['Timesteps'] = '~',
                                ['MSE Error'] = '~',
                                ['Cosine Difference'] = '~',
                                ['Magnitude Difference'] = '~',
                                ['Velocity Error'] = '~',
                                ['Angular Velocity Error'] = '~',
                            }
    end
    collectgarbage()
end

-- eventually move this to variable_object_model
-- function inspect_hidden_state(dataloader, params_)
--     local all_euc_dist = {}
--     local all_euc_dist_diff = {}
--     local all_effects_norm = {}
--     for i = 1, dataloader.num_batches do
--         local batch, current_dataset = dataloader:sample_sequential_batch(false)  -- actually you'd do this for multiple batches
--         local euc_dist = model:get_euc_dist(batch[1], batch[2]) -- table of length num_context of {bsize}
--         local euc_dist_diff = model:get_velocity_direction(batch[1], batch[2])

--         local loss, pred = model:fp(params_,batch,true)
--         local effects = model.network:listModules()[2].output  -- effects[1] corresponds to context[{{},{1}}]  (bsize, rnn_dim)
--         local effects_norm = {}  -- table of length num_context of {bsize}
--         for j=1,#effects do
--             table.insert(effects_norm, torch.squeeze(effects[j]:norm(2,2)))  -- you want to normalize in batch mode!
--         end

--         -- joining the two tables (but if you want to do individaul analysis you wouldn't do this)
--         tablex.insertvalues(all_euc_dist,euc_dist)
--         tablex.insertvalues(all_euc_dist_diff, euc_dist_diff)
--         tablex.insertvalues(all_effects_norm,effects_norm)
--     end
--     all_euc_dist = torch.cat(all_euc_dist)
--     all_euc_dist_diff = torch.cat(all_euc_dist_diff)
--     all_effects_norm = torch.cat(all_effects_norm)


--     -- here let's split into positive and negative velocity
--     -- positive velocity is going away and negative velocity is going towards
--     local neg_vel_idx = torch.squeeze(all_euc_dist_diff:lt(0):nonzero())  -- indices of all_euc_dist_diff that are negative
--     local pos_vel_idx = torch.squeeze(all_euc_dist_diff:ge(0):nonzero())  -- >=0; moving away

--     local neg_vel = all_euc_dist_diff:index(1,neg_vel_idx)
--     local pos_vel = all_euc_dist_diff:index(1,pos_vel_idx)

--     local euc_dist_neg_vel = all_euc_dist:index(1,neg_vel_idx)
--     local euc_dist_pos_vel = all_euc_dist:index(1,pos_vel_idx)

--     local norm_neg_vel = all_effects_norm:index(1,neg_vel_idx)
--     local norm_pos_vel = all_effects_norm:index(1,pos_vel_idx)

--     -- now, plot euc_dist_neg_vel vs norm_neg_vel and euc_dist_pos_vel vs norm_pos_vel

--     print('all_euc_dist:norm()', all_euc_dist:norm())
--     print('all_euc_dist_diff:norm()', all_euc_dist_diff:norm())
--     print('all_effects_norm:norm()', all_effects_norm:norm())

--     local fname = 'hidden_state_all_testfolders'
--     torch.save(mp.savedir..'/'..fname, {euc_dist=all_euc_dist, 
--                                 euc_dist_diff=all_euc_dist_diff, 
--                                 effects_norm=all_effects_norm})

--     local plot_tensor_file = hdf5.open(mp.savedir..'/'..fname..'.h5', 'w')
--     plot_tensor_file:write('euc_dist', all_euc_dist)
--     plot_tensor_file:write('euc_dist_diff', all_euc_dist_diff)
--     plot_tensor_file:write('effects_norm', all_effects_norm)
--     plot_tensor_file:close()
--     print('saved to '..mp.savedir..'/'..fname..'.h5')
--     if mp.server == 'pc' then
--         -- plot_hid_state(fname, all_euc_dist, all_effects_norm, '+')
--         plot_hid_state(fname..'_toward', euc_dist_neg_vel, norm_neg_vel)
--         plot_hid_state(fname..'_away', euc_dist_pos_vel, norm_pos_vel)

--     end
-- end


-- TODO_lowpriority: move this to plot_results
function plot_hid_state(fname, x,y)
    gnuplot.pngfigure(mp.savedir..'/'..fname..'.png')
    gnuplot.xlabel('Euclidean Distance')
    gnuplot.ylabel('Hidden State Norm')
    gnuplot.title('Pairwise Hidden State as a Function of Distance from Focus Object')
    gnuplot.plot(x, y, '+')
    gnuplot.plotflush()
    print('Saved plot of hidden state to '..mp.savedir..'/'..fname..'.png')
end


function save_ex_pred_json(example, jsonfile, current_dataset, subfolder)
    print(current_dataset)
    -- local flags = pls.split(mp.test_dataset_folders[current_dataset], '_')
    local flags = pls.split(current_dataset, '_')

    local world_config = {
        num_past = mp.num_past,
        num_future = mp.num_future,
        env=flags[1],--test_loader.scenario,
        numObj=tonumber(extract_flag(flags, 'n')),
        gravity=false, -- TODO
        friction=false, -- TODO
        pairwise=false -- TODO
    }

    -- first join on the time axis
    -- you should save context pred as well as context future
    local this_past, context_past,
            this_future, context_future,
            this_pred, context_pred = unpack(example)

    -- construct gnd truth (could move to this to a util function)
    local this_pred_traj = torch.cat({this_past, this_pred}, 2)
    local context_pred_traj = torch.cat({context_past,context_pred}, 3)
    dp:record_trajectories({this_pred_traj, context_pred_traj}, world_config, subfolder..'pred_' .. jsonfile)

    -- construct prediction
    local this_gt_traj = torch.cat({this_past, this_future}, 2)
    local context_gt_traj = torch.cat({context_past, context_future}, 3)
    dp:record_trajectories({this_gt_traj, context_gt_traj}, world_config, subfolder..'gt_' .. jsonfile)
end

function getLastSnapshot(network_name)

    -- TODO_lowpriority: this should be replaced by savedir!
    local res_file = io.popen("ls -t "..mp.logs_root..'/'..network_name..
                                " | grep -i epoch | head -n 1")
    local status, result = pcall(function()
                return res_file:read():match( "^%s*(.-)%s*$" ) end)
    print('Last Snapshot: '..result)
    res_file:close()
    if not status then
        return false
    else
        return result
    end
end

function run_inspect_hidden_state()
    local snapshot = getLastSnapshot(mp.name)
    local snapshotfile = mp.savedir ..'/'..snapshot
    print('Snapshot file: '..snapshotfile)
    local checkpoint = torch.load(snapshotfile)

    local saved_args = torch.load(mp.savedir..'/args.t7')
    mp = merge_tables(saved_args.mp, mp) -- overwrite saved mp with our mp when applicable
    config_args = saved_args.config_args

    model_deps(mp.model)
    inittest(true, snapshotfile, {sim=false, subdivide=true})  -- assuming the mp.savedir doesn't change

    inspect_hidden_state(test_loader, checkpoint.model.theta.params, true, mp.steps)
end


function predict_simulate_all()
    local checkpoint, snapshotfile = load_most_recent_checkpoint()

    inittest(true, snapshotfile, {sim=true, subdivide=false})  -- assuming the mp.savedir doesn't change
    require 'infer'
    print('Network parameters')
    print(mp)

    for i,testdataset_loader in pairs(test_loader.datasamplers) do
        print('Evaluating '..test_loader.dataset_folders[i])
        simulate_all(testdataset_loader, checkpoint.model.theta.params, true, mp.steps)
    end
end

function load_most_recent_checkpoint()
    local snapshot = getLastSnapshot(mp.name)
    return load_checkpoint(snapshot)
end

-- 'step9' for mixed
function load_specified_checkpoint(tag)
    local checkpoints = get_all_checkpoints(mp.logs_root, mp.name)
    for _,c in pairs(checkpoints) do
        if not(string.find(c, tag) == nil) then
            return load_checkpoint(c)
        end
    end
    assert(false, 'You should not reah this point')
end

function get_all_checkpoints(logs_folder, experiment_name)
    -- iterate through snapshots
    local res_file = io.popen("ls -t "..mp.logs_root..'/'..mp.name..
                            " | grep -i epoch")
    local checkpoints = {}
    while true do
        local result = res_file:read()
        if result == nil then break end
        print('Adding snapshot: '..result)
        table.insert(checkpoints, result)
    end
    return checkpoints
end

function load_checkpoint(snapshot)
    local snapshotfile = mp.savedir ..'/'..snapshot
    local checkpoint = torch.load(snapshotfile)
    local saved_args = torch.load(mp.savedir..'/args.t7')
    mp = merge_tables(saved_args.mp, mp) -- overwrite saved mp with our mp when applicable
    config_args = saved_args.config_args

    -- NOTE THIS IS ONLY FOR THE EXPERIMENTS THAT DON'T HAVE object_base_size_ids_upper!
    config_args.object_base_size_ids_upper={60,80*math.sqrt(2)/2,math.sqrt(math.pow(60,2)+math.pow(60/3,2))}

    model_deps(mp.model)
    return checkpoint, snapshotfile
end

function inference(logfile, property, method, cf)
    local checkpoints = get_all_checkpoints(mp.logs_root, mp.name)

    local inferenceLogger = optim.Logger(paths.concat(mp.savedir ..'/', logfile))
    inferenceLogger.showPlot = false

    -- iterate through checkpoints backwards (least recent to most recent)
    for i=#checkpoints,1,-1 do
        print(property..' inference on snapshot '..checkpoints[i])

        local checkpoint, snapshotfile = load_checkpoint(checkpoints[i])

        inittest(true, snapshotfile, {sim=false, subdivide=true})  -- assuming the mp.savedir doesn't change
        require 'infer'

        -- save num_correct into a file
        local accuracy, accuracy_by_speed, accuracy_by_mass = infer_properties(model, test_loader, checkpoint.model.theta.params, property, method, cf)
        print('Accuracy',accuracy)
        inferenceLogger:add{[property..' accuracy (test set)'] = accuracy}
        inferenceLogger:style{[property..' accuracy (test set)'] = '~'}
    end
    print('Finished '..property..' inference')
end

function property_analysis_all(logfile, property)
    local checkpoints = get_all_checkpoints(mp.logs_root, mp.name)

    local analysisLogger = optim.Logger(paths.concat(mp.savedir ..'/', logfile))
    analysisLogger.showPlot = false

    -- iterate through checkpoints backwards (least recent to most recent)
    for i=#checkpoints,1,-1 do
        print(' property analysis on snapshot '..checkpoints[i])

        local checkpoint, snapshotfile = load_checkpoint(checkpoints[i])

        inittest(true, snapshotfile, {sim=false, subdivide=true})  -- assuming the mp.savedir doesn't change
        require 'infer'

        local avg_property, num_property = property_analysis(model, test_loader, checkpoint.model.theta.params, property)
        print(avg_property, num_property)

        local metrics = {'loss', 'vel_loss', 'ang_loss', 'avg_ang_error', 'avg_rel_mag_error'} -- TODO! need to do cosine distance and magnitude!

        print('avg_property')
        local logger_table = {}
        local logger_table_style = {}
        for k,v in pairs(avg_property) do
            print(k)
            print(v)

            for m,n in pairs(torch.totable(torch.squeeze(v))) do
                print(metrics[m]..'_'..k)
                print(n)

                logger_table[metrics[m]..'_'..k] = n
                logger_table_style[metrics[m]..'_'..k] = '~'   
            end
        end

        print(logger_table)

        analysisLogger:add(logger_table)
        analysisLogger:style(logger_table_style)   
    end
    print('Finished property analysis')
end



local function test_vel_angvel(dataloader, params_, saveoutput, num_batches)
    local sum_loss = 0
    local num_batches = num_batches or dataloader.total_batches

    num_batches = math.min(5000, num_batches)
    print('Testing '..num_batches..' batches')
    local total_avg_vel = 0
    local total_avg_ang_vel = 0
    local total_avg_loss = 0
    local total_avg_ang_error = 0
    local total_avg_rel_mag_error = 0

    for i = 1,num_batches do
        if mp.server == 'pc' then xlua.progress(i, num_batches) end
        local batch = dataloader:sample_sequential_batch(false)
        local loss, pred, avg_batch_vel, avg_batch_ang_vel  = model:fp(params_, batch)

        local avg_angle_error, avg_relative_magnitude_error = angle_magnitude(pred, batch)

        total_avg_vel = total_avg_vel+ avg_batch_vel
        total_avg_ang_vel = total_avg_ang_vel + avg_batch_ang_vel
        total_avg_loss = total_avg_loss + loss
        total_avg_ang_error = total_avg_ang_error + avg_angle_error
        total_avg_rel_mag_error = total_avg_rel_mag_error + avg_relative_magnitude_error
    end
    total_avg_vel = total_avg_vel/num_batches
    total_avg_ang_vel = total_avg_ang_vel/num_batches
    total_avg_loss = total_avg_loss/num_batches
    total_avg_ang_error = total_avg_ang_error/num_batches
    total_avg_rel_mag_error = total_avg_rel_mag_error/num_batches

    if mp.cuda then cutorch.synchronize() end
    collectgarbage()
    return total_avg_loss, total_avg_vel, total_avg_ang_vel, total_avg_ang_error, total_avg_rel_mag_error
end


function test_vel_angvel_all()
    local checkpoints = get_all_checkpoints(mp.logs_root, mp.name)

    local eval_data = {}

    -- iterate through checkpoints backwards (least recent to most recent)
    for i=#checkpoints,1,-1 do
        local checkpoint, snapshotfile = load_checkpoint(checkpoints[i])
        inittest(true, snapshotfile, {sim=false, subdivide=true})  -- assuming the mp.savedir doesn't change
        require 'infer'

        local checkpoint_eval_data = torch.zeros(#test_loader.datasamplers, 5)  -- (num_samplers, [avg_vel_loss, avg_ang_vel_loss])

        for i,testdataset_loader in pairs(test_loader.datasamplers) do
            print('Evaluating '..test_loader.dataset_folders[i])
            local avg_loss, avg_vel_loss, avg_ang_vel_loss, avg_ang_error, avg_rel_mag_error = test_vel_angvel(testdataset_loader, checkpoint.model.theta.params, false)
            print(avg_loss, avg_vel_loss, avg_ang_vel_loss, avg_ang_error, avg_rel_mag_error)
            checkpoint_eval_data[{{i},{}}] = torch.Tensor{avg_loss, avg_vel_loss, avg_ang_vel_loss, avg_ang_error, avg_rel_mag_error}
        end

        table.insert(eval_data, checkpoint_eval_data:clone():reshape(1,#test_loader.datasamplers,5))
    end

    -- need to transpose
    eval_data = torch.cat(eval_data,1)  -- (num_checkpoints, num_samplers, 5)
    eval_data = eval_data:transpose(1,2) -- (num_samplers, num_checkpoints, 5)

    print(eval_data)
    print(eval_data:gt(0))

    -- iterate through samplers
    for s,testdataset_loader in pairs(test_loader.datasamplers) do
        local experiment_name = paths.basename(testdataset_loader.dataset_folder)
        local subfolder = mp.savedir .. '/' .. experiment_name .. '_predictions/'
        if not paths.dirp(subfolder) then paths.mkdir(subfolder) end

        local logfile = 'tva.log'
        local tvaLogger = optim.Logger(paths.concat(subfolder, logfile))  -- this should be dataloader specific!
        tvaLogger.showPlot = false

        for c=1,#checkpoints do
            tvaLogger:add{['loss'] = eval_data[{{s},{c},{1}}]:sum(), 
                          ['vel_loss'] = eval_data[{{s},{c},{2}}]:sum(),
                          ['ang_vel_loss'] = eval_data[{{s},{c},{3}}]:sum(),
                          ['avg_ang_error'] = eval_data[{{s},{c},{4}}]:sum(),
                          ['avg_rel_mag_error'] = eval_data[{{s},{c},{5}}]:sum()}
            tvaLogger:style{['loss'] = '~',
                            ['vel_loss'] = '~',
                            ['ang_vel_loss'] = '~',
                            ['avg_ang_error'] = '~',
                            ['avg_rel_mag_error'] = '~'}
        end
    end
end


function predict_test_first_timestep_all()
    local checkpoint, snapshotfile = load_most_recent_checkpoint()
    inittest(true, snapshotfile, {sim=false, subdivide=false})  -- assuming the mp.savedir doesn't change
    print('Network parameters')
    print(mp)

    for i,testdataset_loader in pairs(test_loader.datasamplers) do
        print('Evaluating '..test_loader.dataset_folders[i])
        local avg_loss, avg_vel_loss, avg_ang_vel_loss = test_vel_angvel(testdataset_loader, checkpoint.model.theta.params, true)
        print('avg_loss', avg_loss, 'avg_vel_loss', avg_vel_loss, 'avg_ang_vel_loss', avg_ang_vel_loss)
    end
end


function mass_inference()
    inference('mass_infer_cf.log', 'mass', 'max_likelihood', true)
end

-- note that here we need to do inference on the context!
function size_inference()
    inference('size_infer_cf.log', 'size', 'max_likelihood_context', true)
end

-- note that here we need to do inference on the context!
function objtype_inference()
    inference('objtype_infer_cf.log', 'objtype', 'max_likelihood_context', true)
end

function pmofm_b2i_inference()
    inference('pmofm_b2i_infer_cf.log', 'pos_mass_oid_fixedmass', 'backprop', true)
end

function size_analysis()
    property_analysis_all('size_analysis.log', 'size')
end

function oid_analysis()
    property_analysis_all('oid_analysis.log', 'objtype')
end

function predict_b2i()
    local snapshot = getLastSnapshot(mp.name)
    local snapshotfile = mp.savedir ..'/'..snapshot
    local checkpoint = torch.load(snapshotfile)
    checkpoint = checkpointtocuda(checkpoint)
    mp = merge_tables(checkpoint.mp, mp)
    model_deps(mp.model)
    inittest(true, snapshotfile)  -- assuming the mp.savedir doesn't change
    backprop2input()
end

function model_deps(modeltype)
    if modeltype == 'lstmobj' or
            modeltype == 'ffobj' or
                    modeltype == 'gruobj' then
        M = require 'variable_obj_model'
    elseif modeltype == 'bffobj' then
        M = require 'branched_variable_obj_model'
    elseif modeltype == 'np' then
        M = require 'nop'
    elseif modeltype == 'ind' then
        M = require 'independent'
    elseif modeltype == 'bl' then
        M = require 'blstm'
    elseif modeltype == 'lstm' then
        M = require 'lstm'
    elseif modeltype == 'ff' then
        M = require 'feed_forward_model'
    else
        error('Unrecognized model')
    end
end


------------------------------------- Main -------------------------------------
if mp.mode == 'sim' then
    predict_simulate_all()
    -- run_inspect_hidden_state() -- I'm just getting the hidden state here
elseif mp.mode == 'hid' then
    run_inspect_hidden_state()
elseif mp.mode == 'minf' then
    mass_inference()
elseif mp.mode == 'sinf' then
    size_inference()
elseif mp.mode == 'oinf' then
    objtype_inference()
elseif mp.mode == 'pmofminf' then
    pmofm_b2i_inference()
elseif mp.mode == 'b2i' then
    predict_b2i()
elseif mp.mode == 'pred' then
    predict()
elseif mp.mode == 'tva' then
    test_vel_angvel_all()
elseif mp.mode == 'tf' then
    predict_test_first_timestep_all()
elseif mp.mode == 'pa' then
    property_analysis_all()
elseif mp.mode == 'sa' then
    size_analysis()
elseif mp.mode == 'oia' then
    oid_analysis()
else
    error('unknown mode')
end
