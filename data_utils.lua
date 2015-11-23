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