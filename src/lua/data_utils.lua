-- require 'hdf5'
require 'nn'
require 'nngraph'
require 'torchx'
local pltx = require 'pl.tablex'
local pls = require 'pl.stringx'

function get_keys(table)
    local keyset={}
    local n=0

    for k,v in pairs(table) do
        n=n+1
        keyset[n]=k
    end
    return keyset
end

function split_table(table, num_chunks)
    --[[
        input
            :type table: table
            :param table: table of elements

            :type num_chunks: int
            :param num_chunks: number of chunks you want to split the table into
        output
            :type: table of subtables
            :value: the number of subtables is num_chunks, each of size math.floor(#table/num_chunks)
    --]]
    local n = #table
    local chunk_size = math.floor(n/num_chunks)
    local splitted_table = {}
    local current_chunk = {}
    for i = 1, n do
        current_chunk[#current_chunk+1] = table[i]
        if i % chunk_size == 0 then
            splitted_table[#splitted_table+1] = current_chunk
            current_chunk = {}
        end
    end
    collectgarbage()
    return splitted_table
end

function find_all_sequences(folders_list, parent_folder_path, seq_length)
    local data_list = {}
    for f = 1, #folders_list do
        local data_path = parent_folder_path .. '/' .. folders_list[f]

        -- get number of images in this folder
        local num_images_f = io.popen('ls "' .. data_path .. '" | wc -l')
        local num_images = nil
        for x in num_images_f:lines() do num_images = x end
        local num_examples = math.floor(num_images/(seq_length))
        num_images = num_examples*seq_length

        -- cycle through images
        local p = io.popen('find "' .. data_path .. '" -type f -name "*.png"')  -- Note: this is not in order!
        local j = 0
        local ex_string = {}
        for img_name in p:lines() do
            j = j + 1
            ex_string[#ex_string+1] = data_path .. '/' .. j .. '.png'  -- force the images to be in order
            if j % seq_length == 0 then
                data_list[#data_list+1] = ex_string
                ex_string = {}
            end
        end
    end
    collectgarbage()
    return data_list
end

function save_to_hdf5(filename, data)
    -- filename: name of hdf5 file
    -- data: dict of {datapath: data}
    local myFile = hdf5.open(filename, 'w')
    for k,v in pairs(data) do
        myFile:write(k, v)  -- I can write many preds in here, indexed by the starting time?
    end
    myFile:close()
end


function concatenate_table(table)
    -- concatenates a table of torch tensors
    print(table)
    local num_tensors = #table
    print('num_tensors')
    print(num_tensors)
    local other_dims = table[1]:size()
    local dims = {num_tensors, unpack(other_dims:totable())}
    print('dims')
    print(dims)

    -- construct container
    local container = torch.zeros(unpack(dims))
    for i=1,num_tensors do
        container[{{i}}] = table[i]
    end
    return container
end

function convert_type(x, should_cuda)
    if should_cuda then
        return x:cuda()
    else
        return x:float()
    end
end


-- tensor (batchsize, winsize*obj_dim)
-- reshapesize (batchsize, winsize, obj_dim)
-- cropdim (dim, amount_to_take) == (dim, mp.num_future)
function crop_future(tensor, reshapesize, cropdim)
    print('crop_future')
    print(tensor:size())
    print(reshapesize)
    print(cropdim)

    local crop = tensor:clone()
    crop = crop:reshape(unpack(reshapesize))
    --hacky
    if crop:dim() == 3 then
        assert(cropdim[1]==2)
        crop = crop[{{},{1,cropdim[2]},{}}]  -- (num_samples x num_future x 8)
        crop = crop:reshape(reshapesize[1], cropdim[2] * mp.object_dim)
    else
        assert(crop:dim()==4 and cropdim[1] == 3)
        crop = crop[{{},{},{1,cropdim[2]},{}}]
        crop = crop:reshape(reshapesize[1], mp.seq_length,
                            cropdim[2] * mp.object_dim)
    end
    return crop
end

-- dim will be where the one is, and the dimensions after will be shifted right
function broadcast(tensor, dim)
    local ndim = tensor:dim()

    if dim == 1 then
        return tensor:reshape(1,unpack(torch.totable(tensor:size())))
    elseif dim == ndim + 1 then
        local dims = {unpack(torch.totable(tensor:size())),1}
        return tensor:reshape(unpack(dims))
    elseif dim > 1 and dim <= ndim then
        local before = torch.Tensor(torch.totable(tensor:size()))[{{1,dim-1}}]
        local after = torch.Tensor(torch.totable(tensor:size()))[{{dim,-1}}]
        print(before)
        print(after)
        print(unpack(torch.totable(before)))
        local a = {unpack(torch.totable(before)),1,unpack(torch.totable(after))}
        local b = {unpack(torch.totable(before)),1}
        print(a)
        print(b)
        return tensor:reshape(unpack(torch.totable(before)), 1,
                                unpack(torch.totable(after)))
    else
        error('invalid dim')
    end
end


function extract_flag(flags_list, delim)
    local extract = pltx.filter(flags_list, function(x) return pls.startswith(x, delim) end)
    assert(#extract == 1)
    return string.sub(extract[1], #delim+1)
end


-- each inner table contains the same number of tensors, for which all
-- the dimensions (except the first) are the same
function join_table_of_tables(table_of_tables)
    if #table_of_tables == 0 then return table_of_tables end
    local all
    for _, inner in pairs(table_of_tables) do
        if all == nil then
            all = pltx.deepcopy(inner)
        else
            for k, tensor in pairs(inner) do
                all[k] = torch.cat({all[k], tensor:clone()}, 1)
            end
        end
    end
    return all
end


function preprocess_input(mask)
    -- in: {(bsize, input_dim), (bsize, mp.seq_length, input_dim)}
    -- out: table of length torch.find(mask,1)[1] of pairs {(bsize, input_dim), (bsize, input_dim)}

    local this_past = nn.Identity()()
    local context = nn.Identity()()

    -- this: (bsize, input_dim)
    -- context: (bsize, mp.seq_length, dim)
    local input = {}
    for t = 1, torch.find(mask,1)[1] do
        table.insert(input, nn.Identity()
                        ({this_past, nn.Squeeze()(nn.Select(2,t)(context))}))
    end
    input = nn.Identity()(input)
    return nn.gModule({this_past, context}, {input})
end


function checkpointtofloat(checkpoint)
    -- just mutates checkpoint though
    checkpoint.model.network:clearState()
    checkpoint.model.network:float()
    checkpoint.model.criterion:float()
    checkpoint.model.identitycriterion:float()
    checkpoint.model.theta.params = checkpoint.model.theta.params:float()
    checkpoint.model.theta.grad_params=checkpoint.model.theta.grad_params:float()
    return checkpoint
end

function checkpointtocuda(checkpoint)
    -- just mutates checkpoint though
    checkpoint.model.network:clearState()
    checkpoint.model.network:cuda()
    checkpoint.model.criterion:cuda()
    checkpoint.model.identitycriterion:cuda()
    checkpoint.model.theta.params = checkpoint.model.theta.params:cuda()
    checkpoint.model.theta.grad_params=checkpoint.model.theta.grad_params:cuda()
    return checkpoint
end

function unsqueeze(tensor, dim)
    local ndims = tensor:dim()
    assert(dim >= 1 and dim <= ndims+1 and dim % 1 ==0,
            'can only unsqueeze up to one extra dimension')
    local old_size = torch.totable(tensor:size())
    local j = 1
    local new_size = {}
    for i=1,ndims+1 do
        if i == dim then
            table.insert(new_size, 1)
        else
            table.insert(new_size, old_size[j])
            j = j + 1
        end
    end
    tensor = tensor:clone():reshape(unpack(new_size))
    return tensor
end

function mj_interface(batch)
    -- {
    --   1 : FloatTensor - size: 50x2x9
    --   2 : FloatTensor - size: 50x10x2x9
    --   3 : FloatTensor - size: 50x2x9
    --   4 : FloatTensor - size: 10
    --   5 : "worldm5_np=2_ng=0_slow"
    --   6 : 1
    --   7 : 50
    --   8 : FloatTensor - size: 50x10x2x9
    -- }

    local focus_past = batch[1]
    local context_past = batch[2]
    local focus_future = batch[3]
    local mask = batch[4]
    local config_name = batch[5]
    local start = batch[6]
    local finish = batch[7]
    local context_future = batch[8]

    return {focus_past, context_past, focus_future, context_future, mask}
end

-- b and a must be same size
function compute_euc_dist(a,b)
    -- print('hey')
    assert(a:dim()==3 and b:dim()==3)
    assert(alleq({torch.totable(a:size()), torch.totable(b:size())}))
    assert(a:size(3)==2)
    local diff = torch.squeeze(b - a, 3) -- (bsize, num_context, 2)
    local diffsq = torch.pow(diff,2)
    local euc_dists = torch.sqrt(diffsq[{{},{},{1}}]+diffsq[{{},{},{2}}])  -- (bsize, num_context, 1)
    return euc_dists
end

function num2onehot(value, categories, cuda)
    local index = torch.find(torch.Tensor(categories), value)[1]
    assert(not(index == nil))
    local onehot = convert_type(torch.zeros(#categories), cuda)
    onehot[{{index}}]:fill(1)  -- will throw an error if index == nil
    return onehot
end

function onehot2num(onehot, categories)
    assert(onehot:sum() == 1 and #torch.find(onehot, 1) == 1)
    return categories[torch.find(onehot, 1)[1]]
end

function num2onehotall(selected, categories, cuda)
    local num_ex = selected:size(1)
    local num_obj = selected:size(2)
    local num_steps = selected:size(3)

    -- expand
    selected = torch.repeatTensor(selected, 1, 1, 1, #categories)  -- I just want to tile on the last dimension
    selected = selected:reshape(num_ex*num_obj*num_steps, #categories)

    for row=1,selected:size(1) do
        selected[{{row}}] = num2onehot(selected[{{row},{1}}]:sum(), categories, cuda)
    end
    selected = selected:reshape(num_ex, num_obj, num_steps, #categories)
    return selected
end


function onehot2numall(onehot_selected, categories, cuda)
    local num_ex = onehot_selected:size(1)
    local num_obj = onehot_selected:size(2)
    local num_steps = onehot_selected:size(3)

    local selected = convert_type(torch.zeros(num_ex*num_obj*num_steps, 1), cuda)  -- this is not cuda-ed!
    onehot_selected = onehot_selected:reshape(num_ex*num_obj*num_steps, #categories)  -- I get weird numbers if I use resize and the num_steps = 1

    for row=1,onehot_selected:size(1) do
        selected[{{row}}] = onehot2num(torch.squeeze(onehot_selected[{{row}}]), categories)
    end
    selected = selected:reshape(num_ex, num_obj, num_steps, 1)
    return selected
end

function get_oid_templates(this, config_args, cuda)

    local bsize = this:size(1)

    -- make threshold depend on object id!
    local oid_onehot = torch.squeeze(this[{{},{-1},config_args.si.oid}],2)  -- all are same   -- only need one timestep
    local num_oids = config_args.si.oid[2]-config_args.si.oid[1]+1
    local template = convert_type(torch.zeros(bsize, num_oids), cuda)  -- only need one timestep
    local template_ball = template:clone()
    local template_block = template:clone()
    local template_obstacle = template:clone()
    template_ball[{{},{config_args.oids.ball}}]:fill(1)
    template_block[{{},{config_args.oids.block}}]:fill(1)
    template_obstacle[{{},{config_args.oids.obstacle}}]:fill(1)

    return oid_onehot, template_ball, template_block, template_obstacle

end