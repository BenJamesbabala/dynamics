-- Train DDCIGN 

require 'metaparams'
require 'torch'
require 'nn'
require 'nngraph'
require 'optim'
require 'model'
require 'image'
require 'rmsprop'
require 'paths' 
-- require 'math'

if common_mp.cuda then require 'cutorch' end
if common_mp.cunn then require 'cunn' end

local DataLoader = require 'DataLoader'
local model_utils = require 'model_utils'

local Trainer = {}
Trainer.__index = Trainer

function Trainer.create(dataset, mp)
    local self = {}
    setmetatable(self, Trainer)
    self.mp = mp
    self.dataset = dataset  -- string name of folder containing trainig examples
    self.train_loader = DataLoader.create(self.dataset, self.mp.dataset_folder, self.mp.batch_size, self.mp.curriculum, self.mp.shuffle)
    collectgarbage()
    return self
end

function Trainer:prepare_logs(learning_rate)
    self.mp.learning_rate = learning_rate
    self.logs = {}
    self.cmd = torch.CmdLine()
    self.logs.savefile = common_mp.results_folder .. '/saved_model,lr=' .. self.mp.learning_rate .. '.t7'
    self.logs.lossesfile = common_mp.results_folder .. '/losses,lr=' .. self.mp.learning_rate .. '_results.t7'
    self.logs.train_losses = {losses={}, grad_norms={}}

    if not paths.dirp(common_mp.results_folder) then paths.mkdir(common_mp.results_folder) end

    collectgarbage()
end

function Trainer:create_model()
    self.network = init_network(self.mp)
    if common_mp.cuda then self.network:cuda() end

    ------------------------------------- Parameters -------------------------------------
    self.theta = {}
    self.theta.params, self.theta.grad_params = self.network:getParameters()
    print('self.theta.params', #self.theta.params)

    ------------------------------------ Clone Model -------------------------------------
    self.rnns = model_utils.clone_many_times(self.network, self.mp.seq_length, not self.network.parameters)

    -------------------------------- Initialize LSTM State -------------------------------
    -- This will cache the values that s takes on in one forward pass
    self.s = {}
    for j = 0, self.mp.seq_length do
        self.s[j] = {}
        for d = 1, 2 * self.mp.layers do
            self.s[j][d] = model_utils.transfer_data(torch.zeros(self.mp.batch_size, self.mp.rnn_dim), common_mp.cuda) 
        end
    end
    -- This will cache the values of the grad of the s 
    self.ds = {}
    for d = 1, 2 * self.mp.layers do
        self.ds[d] = model_utils.transfer_data(torch.zeros(self.mp.batch_size, self.mp.rnn_dim), common_mp.cuda)
    end

    collectgarbage()
end


function Trainer:reset_state()
    for j = 0, self.mp.seq_length do
        for d = 1, 2 * self.mp.layers do
            self.s[j][d]:zero()
        end
    end
end

function Trainer:reset_ds()
    for d = 1, #self.ds do
        self.ds[d]:zero()
    end
end

-- reset state before the forward pass
-- reset ds before the backward pass


function Trainer:forward_pass_train(params_, x, y)
    -- x is a table!
    if params_ ~= self.theta.params then self.theta.params:copy(params_) end
    self.theta.grad_params:zero()  -- reset gradient
    self:reset_state()  -- reset s

    -- unpack inputs
    local this_past     = model_utils.transfer_data(x.this:clone(), common_mp.cuda)
    local context       = model_utils.transfer_data(x.context:clone(), common_mp.cuda)
    local this_future   = model_utils.transfer_data(y:clone(), common_mp.cuda)

    assert(this_past:size(1) == self.mp.batch_size and this_past:size(2) == self.mp.input_dim)
    assert(context:size(1) == self.mp.batch_size and context:size(2)==self.mp.seq_length
            and context:size(3) == self.mp.input_dim)
    assert(this_future:size(1) == self.mp.batch_size and this_future:size(2) == self.mp.input_dim)

    local loss = model_utils.transfer_data(torch.zeros(self.mp.seq_length), common_mp.cuda)
    local predictions = {}
    for i = 1, self.mp.seq_length do
        local sim1 = self.s[i-1]  -- had been reset to 0 for initial pass
        loss[i], self.s[i], predictions[i] = unpack(self.rnns[i]:forward({this_past, context[{{},i}], sim1, this_future}))  -- problem! (feeding thisp_future every time; is that okay because I just update the gradient based on desired timesstep?)
    end 

    collectgarbage()
    return loss:sum(), self.s, predictions
end


function Trainer:backward_pass_train(x, y, mask, loss, state, predictions)
    -- loss and predictions are unused

    -- assert that state equals self.s
    for j = 0, self.mp.seq_length do
        for d = 1, 2 * self.mp.layers do
            assert(torch.sum(state[j][d]:eq(self.s[j][d])) == torch.numel(self.s[j][d]))
        end
    end 

    self.theta.grad_params:zero()
    self:reset_ds()

    -- unpack inputs. All of these have been CUDAed already if need be
    local this_past     = model_utils.transfer_data(x.this:clone(), common_mp.cuda)
    local context       = model_utils.transfer_data(x.context:clone(), common_mp.cuda)
    local this_future   = model_utils.transfer_data(y:clone(), common_mp.cuda)

    for i = self.mp.seq_length, 1, -1 do
        local sim1 = state[i - 1]
        local derr
        if mask:clone()[i] == 1 then 
            derr = model_utils.transfer_data(torch.ones(1), common_mp.cuda)
        elseif mask:clone()[i] == 0 then
            derr = model_utils.transfer_data(torch.zeros(1), common_mp.cuda)
        else
            error('invalid mask')
        end
        local dpred = model_utils.transfer_data(torch.zeros(self.mp.batch_size,self.mp.out_dim), common_mp.cuda)
        local dtp, dc, dsim1, dtf = unpack(self.rnns[i]:backward({this_past, context[{{},i}], sim1, this_future}, {derr, self.ds, dpred}))
        g_replace_table(self.ds, dsim1)
        -- cutorch.synchronize()
    end
    self.theta.grad_params:clamp(-self.mp.max_grad_norm, self.mp.max_grad_norm)
    collectgarbage()
    return loss, self.theta.grad_params
end


function Trainer:reset(learning_rate)
    self:prepare_logs(learning_rate)
    self:create_model()  -- maybe put this into constructor
end


function Trainer:train(num_iters, epoch_num)

    function feval_train(params_)
        -- feval MUST return loss, grad_loss in order to get fed into the optimizer!
        local this, context, y, mask = unpack(self.train_loader:next_batch())  -- the way it is defined in loader is to just keep cycling through the same dataset
        local train_loss, state, predictions = self:forward_pass_train(params_, {this=this,context=context}, y)
        local loss, grad_loss = self:backward_pass_train({this=this,context=context}, y, mask, train_loss, state, predictions)
        assert(loss == train_loss)
        collectgarbage()
        return loss, grad_loss
    end

    -- here do epoch training
    local optim_state = {learningRate = self.mp.learning_rate,
                         momentumDecay = 0.1, 
                         updateDecay = 0.01}

    for i = 1,num_iters do 
        local _, loss = rmsprop(feval_train, self.theta.params, optim_state)  -- this is where the training actually happens
        self.logs.train_losses.losses[#self.logs.train_losses.losses+1] = loss[1]
        self.logs.train_losses.grad_norms[#self.logs.train_losses.grad_norms+1] = self.theta.grad_params:norm()

        -- Update Parameters
        local p, gp = self.network:getParameters()
        p:copy(self.theta.params)
        gp:copy(self.theta.grad_params)

        if i % self.mp.print_every == 0 then
            print(string.format("epoch %2d\titeration %2d\tloss = %6.8f\tgradnorm = %6.4e", epoch_num, i, loss[1], self.theta.grad_params:norm()))
        end

        if i % self.mp.save_every == 0 then 
            torch.save(self.logs.savefile, self.network)
            torch.save(self.logs.lossesfile, self.logs.train_losses)
            print('saved model')
        end
        collectgarbage()
    end
    torch.save(self.logs.savefile, self.network)
    torch.save(self.logs.lossesfile, self.logs.train_losses)

    return self.logs.train_losses.losses[#self.logs.train_losses.losses], self.network --self.logs.savefile
end    


function Trainer:curriculum_train(num_subepochs, epoch_num)
    -- to change: have another loop inside i=1,num_iters
    for config_id=1,self.train_loader.num_configs do
        print('Config:', self.train_loader.configs[config_id]..'--------------------------------------------------------------------')
        local config_this, config_context, config_y, config_mask = unpack(self.train_loader:next_config(self.train_loader.configs[config_id], 1, self.train_loader.config_sizes[config_id]))
        
        for i=1,num_subepochs do -- go through the entire config here
            assert(self.train_loader.config_sizes[config_id]%self.train_loader.batch_size==0)
            local _, loss
            for b=1,self.train_loader.config_sizes[config_id]/self.train_loader.batch_size do
                local finish = b*self.train_loader.batch_size
                local start = finish - self.train_loader.batch_size + 1

                -- get a batch sized chunk
                local this, context, y = unpack(DataLoader.slice_batch({config_this, config_context, config_y}, start, finish))
                local mask = config_mask

                function feval_train(params_)
                    -- feval MUST return loss, grad_loss in order to get fed into the optimizer!
                    -- local this, context, y, mask = unpack(self.train_loader:next_batch())  -- the way it is defined in loader is to just keep cycling through the same dataset
                    local train_loss, state, predictions = self:forward_pass_train(params_, {this=this,context=context}, y)
                    local loss, grad_loss = self:backward_pass_train({this=this,context=context}, y, mask, train_loss, state, predictions)
                    assert(loss == train_loss)
                    collectgarbage()
                    return loss, grad_loss
                end

                local optim_state = {learningRate = self.mp.learning_rate,
                     momentumDecay = 0.1, 
                     updateDecay = 0.01} 

                _, loss = rmsprop(feval_train, self.theta.params, optim_state)
                self.logs.train_losses.losses[#self.logs.train_losses.losses+1] = loss[1]
                self.logs.train_losses.grad_norms[#self.logs.train_losses.grad_norms+1] = self.theta.grad_params:norm()

                -- Update Parameters
                local p, gp = self.network:getParameters()
                p:copy(self.theta.params)
                gp:copy(self.theta.grad_params)
                -- print(string.format("epoch %2d\tconfig_id %2d\tsubepoch %2d\tbatch %2d\tloss = %6.8f\tgradnorm = %6.4e", epoch_num, config_id, i, b, loss[1], self.theta.grad_params:norm()))
            end
            print(string.format("epoch %2d\tconfig_id %2d\tsubepoch %2d\tloss = %6.8f\tgradnorm = %6.4e", epoch_num, config_id, i, loss[1], self.theta.grad_params:norm()))
        end 
        torch.save(self.logs.savefile, self.network)
        torch.save(self.logs.lossesfile, self.logs.train_losses)
        print('saved model')
    end

    torch.save(self.logs.savefile, self.network)
    torch.save(self.logs.lossesfile, self.logs.train_losses)

    return self.logs.train_losses.losses[#self.logs.train_losses.losses], self.network --self.logs.savefile
end


-- train_mp.batch_size = 3
-- torch.manualSeed(123)
-- trainer = Trainer.create('trainset', train_mp)
-- local lr = 5e-3
-- trainer:reset(lr)
-- for i=0,10 do
--     print('Learning rate:', trainer.mp.learning_rate)
--     trainer:curriculum_train(10, i)
--     trainer.mp.learning_rate=trainer.mp.learning_rate/math.sqrt(2)
-- end

-- final_loss = trainer:train(1000, 0)
-- print(final_loss)

return Trainer



