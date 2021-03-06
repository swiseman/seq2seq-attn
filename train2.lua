require 'nn'
require 'nngraph'
require 'hdf5'

require 's2sa.data2'
require 's2sa.models'
require 's2sa.model_utils'

cmd = torch.CmdLine()

-- data files
cmd:text("")
cmd:text("**Data options**")
cmd:text("")
cmd:option('-data_file','data/demo-train.hdf5', [[Path to the training *.hdf5 file from preprocess.py]])
cmd:option('-val_data_file','data/demo-val.hdf5', [[Path to validation *.hdf5 file from preprocess.py]])
cmd:option('-savefile', 'seq2seq_lstm_attn', [[Savefile name (model will be saved as
                                             savefile_epochX_PPL.t7 where X is the X-th epoch and PPL is
                                             the validation perplexity]])
cmd:option('-num_shards', 0, [[If the training data has been broken up into different shards,
                             then training files are in this many partitions]])
cmd:option('-train_from', '', [[If training from a checkpoint then this is the path to the pretrained model.]])

-- rnn model specs
cmd:text("")
cmd:text("**Model options**")
cmd:text("")

cmd:option('-num_layers', 2, [[Number of layers in the LSTM encoder/decoder]])
cmd:option('-rnn_size', 500, [[Size of LSTM hidden states]])
cmd:option('-word_vec_size', 500, [[Word embedding sizes]])
cmd:option('-attn', 1, [[If = 1, use attention on the decoder side. If = 0, it uses the last
                       hidden state of the decoder as context at each time step.]])
cmd:option('-use_chars_enc', 0, [[If = 1, use character on the encoder side (instead of word embeddings]])
cmd:option('-use_chars_dec', 0, [[If = 1, use character on the decoder side (instead of word embeddings]])
cmd:option('-reverse_src', 0, [[If = 1, reverse the source sequence. The original
                              sequence-to-sequence paper found that this was crucial to
                              achieving good performance, but with attention models this
                              does not seem necessary. Recommend leaving it to 0]])
cmd:option('-init_dec', 1, [[Initialize the hidden/cell state of the decoder at time
                           0 to be the last hidden/cell state of the encoder. If 0,
                           the initial states of the decoder are set to zero vectors]])
cmd:option('-input_feed', 1, [[If = 1, feed the context vector at each time step as additional
                             input (vica concatenation with the word embeddings) to the decoder]])
cmd:option('-multi_attn', 0, [[If > 0, then use a another attention layer on this layer of
                             the decoder. For example, if num_layers = 3 and `multi_attn = 2`,
                             then the model will do an attention over the source sequence
                             on the second layer (and use that as input to the third layer) and
                             the penultimate layer]])
cmd:option('-res_net', 0, [[Use residual connections between LSTM stacks whereby the input to
                          the l-th LSTM layer if the hidden state of the l-1-th LSTM layer
                          added with the l-2th LSTM layer. We didn't find this to help in our
                          experiments]])
cmd:option('-guided_alignment', 0, [[If 1, use external alignments to guide the attention weights as in
                                   (Chen et al., Guided Alignment Training for Topic-Aware Neural Machine Translation,
                                   arXiv 2016.). Alignments should have been provided during preprocess]])
cmd:option('-guided_alignment_weight', 0.5, [[default weights for external alignments]])
cmd:option('-guided_alignment_decay', 1, [[decay rate per epoch for alignment weight - typical with 0.9,
                                         weight will end up at ~30% of its initial value]])

cmd:text("")
cmd:text("Below options only apply if using the character model.")
cmd:text("")

-- char-cnn model specs (if use_chars == 1)
cmd:option('-char_vec_size', 25, [[Size of the character embeddings]])
cmd:option('-kernel_width', 6, [[Size (i.e. width) of the convolutional filter]])
cmd:option('-num_kernels', 1000, [[Number of convolutional filters (feature maps). So the
                                 representation from characters will have this many dimensions]])
cmd:option('-num_highway_layers', 2, [[Number of highway layers in the character model]])

cmd:text("")
cmd:text("**Optimization options**")
cmd:text("")

-- optimization
cmd:option('-epochs', 13, [[Number of training epochs]])
cmd:option('-start_epoch', 1, [[If loading from a checkpoint, the epoch from which to start]])
cmd:option('-param_init', 0.1, [[Parameters are initialized over uniform distribution with support (-param_init, param_init)]])
cmd:option('-optim', 'sgd', [[Optimization method. Possible options are: sgd (vanilla SGD), adagrad, adadelta, adam]])
cmd:option('-learning_rate', 1, [[Starting learning rate. If adagrad/adadelta/adam is used,
                                then this is the global learning rate. Recommended settings: sgd =1,
                                adagrad = 0.1, adadelta = 1, adam = 0.1]])
cmd:option('-layer_lrs', '', [[Comma-separated learning rates for encoder, decoder, and generator. Only used if optim ~= sgd.]])
cmd:option('-max_grad_norm', 5, [[If the norm of the gradient vector exceeds this renormalize it to have the norm equal to max_grad_norm]])
cmd:option('-dropout', 0.3, [[Dropout probability. Dropout is applied between vertical LSTM stacks.]])
cmd:option('-lr_decay', 0.5, [[Decay learning rate by this much if (i) perplexity does not decrease
                             on the validation set or (ii) epoch has gone past the start_decay_at_limit]])
cmd:option('-start_decay_at', 9, [[Start decay after this epoch]])
cmd:option('-curriculum', 0, [[For this many epochs, order the minibatches based on source
                             sequence length. Sometimes setting this to 1 will increase convergence speed.]])
cmd:option('-feature_embeddings_dim_exponent', 0.7, [[If the feature takes N values, then the
                                                    embbeding dimension will be set to N^exponent]])
cmd:option('-pre_word_vecs_enc', '', [[If a valid path is specified, then this will load
                                     pretrained word embeddings (hdf5 file) on the encoder side.
                                     See README for specific formatting instructions.]])
cmd:option('-pre_word_vecs_dec', '', [[If a valid path is specified, then this will load
                                     pretrained word embeddings (hdf5 file) on the decoder side.
                                     See README for specific formatting instructions.]])
cmd:option('-fix_word_vecs_enc', 0, [[If = 1, fix word embeddings on the encoder side]])
cmd:option('-fix_word_vecs_dec', 0, [[If = 1, fix word embeddings on the decoder side]])
cmd:option('-max_batch_l', '', [[If blank, then it will infer the max batch size from validation
                               data. You should only use this if your validation set uses a different
                               batch size in the preprocessing step]])

cmd:text("")
cmd:text("**Other options**")
cmd:text("")

cmd:option('-start_symbol', 0, [[Use special start-of-sentence and end-of-sentence tokens
                               on the source side. We've found this to make minimal difference]])
-- GPU
cmd:option('-gpuid', -1, [[Which gpu to use. -1 = use CPU]])
cmd:option('-gpuid2', -1, [[If this is >= 0, then the model will use two GPUs whereby the encoder
                          is on the first GPU and the decoder is on the second GPU.
                          This will allow you to train with bigger batches/models.]])
cmd:option('-cudnn', 0, [[Whether to use cudnn or not for convolutions (for the character model).
                        cudnn has much faster convolutions so this is highly recommended
                        if using the character model]])
-- bookkeeping
cmd:option('-save_every', 1, [[Save every this many epochs]])
cmd:option('-print_every', 50, [[Print stats after this many batches]])
cmd:option('-seed', 3435, [[Seed for random initialization]])
cmd:option('-prealloc', 1, [[Use memory preallocation and sharing between cloned encoder/decoders]])


local function zero_table(tab)
    for i = 1, #tab do
        tab[i]:zero()
    end
end

function train(train_data, valid_data)

  local timer = torch.Timer()
  local num_params = 0
  local num_prunedparams = 0
  local start_decay = 0
  params, grad_params = {}, {}
  opt.train_perf = {}
  opt.val_perf = {}

  for i = 1, #layers do
    if opt.gpuid2 >= 0 then
      if i == 1 then
        cutorch.setDevice(opt.gpuid)
      else
        cutorch.setDevice(opt.gpuid2)
      end
    end
    local p, gp = layers[i]:getParameters()
    -- if opt.train_from:len() == 0 then
    --   p:uniform(-opt.param_init, opt.param_init)
    -- end
    num_params = num_params + p:size(1)
    params[i] = p
    grad_params[i] = gp
    layers[i]:apply(function (m) if m.nPruned then num_prunedparams=num_prunedparams+m:nPruned() end end)
  end

  if opt.pre_word_vecs_enc:len() > 0 then
    local f = hdf5.open(opt.pre_word_vecs_enc)
    local pre_word_vecs = f:read('word_vecs'):all()
    for i = 1, pre_word_vecs:size(1) do
      word_vec_layers[1].weight[i]:copy(pre_word_vecs[i])
    end
  end


  print("Number of parameters: " .. num_params .. " (active: " .. num_params-num_prunedparams .. ")")

  if opt.gpuid >= 0 and opt.gpuid2 >= 0 then
    cutorch.setDevice(opt.gpuid)
    word_vec_layers[1].weight[1]:zero()
  else
    word_vec_layers[1].weight[1]:zero()
  end


  -- decay learning rate if val perf does not improve or we hit the opt.start_decay_at limit
  function decay_lr(epoch)
    print(opt.val_perf)
    if opt.decay_schedule2 then
        start_decay = 0
    end
    if epoch >= opt.start_decay_at then
      start_decay = 1
    end

    if opt.val_perf[#opt.val_perf] ~= nil and opt.val_perf[#opt.val_perf-1] ~= nil then
      local curr_ppl = opt.val_perf[#opt.val_perf]
      local prev_ppl = opt.val_perf[#opt.val_perf-1]
      if curr_ppl > prev_ppl then
        start_decay = 1
      end
    end
    if start_decay == 1 then
      opt.learning_rate = opt.learning_rate * opt.lr_decay
    end
  end

  function train_batch(data, epoch)
    opt.num_source_features = data.num_source_features

    local train_nonzeros = 0
    local train_loss = 0
    local batch_order = torch.randperm(data.length) -- shuffle mini batch order
    local start_time = timer:time().real
    local num_words_target = 0
    local num_words_source = 0

    for i = 1, data:size() do
      zero_table(grad_params, 'zero')
      local d
      if epoch <= opt.curriculum then
        d = data[i]
      else
        d = data[batch_order[i]]
      end
      local target, target_out, nonzeros, source = d[1], d[2], d[3], d[4]
      local batch_l, target_l, source_l = d[5], d[6], d[7]

      -- forward prop encoder
      encoder:training()
      local preds = encoder:forward(source)

      local loss = criterion:forward(preds, target_out:view(-1))/batch_l
      local dl_dpred = criterion:backward(preds, target_out:view(-1))
      dl_dpred:div(batch_l)
      encoder:backward(source, dl_dpred)

      local grad_norm = 0
      grad_norm = grad_params[1]:norm()

      word_vec_layers[1].gradWeight[1]:zero()
      if opt.fix_word_vecs_enc == 1 then
        word_vec_layers[1].gradWeight:zero()
      end

      -- Shrink norm and update params
      local param_norm = 0
      local shrinkage = opt.max_grad_norm / grad_norm
      for j = 1, #grad_params do
        if opt.gpuid >= 0 and opt.gpuid2 >= 0 then
          if j == 1 then
            cutorch.setDevice(opt.gpuid)
          else
            cutorch.setDevice(opt.gpuid2)
          end
        end
        if shrinkage < 1 then
          grad_params[j]:mul(shrinkage)
        end

        if opt.optim == 'adagrad' then
          adagrad_step(params[j], grad_params[j], layer_etas[j], optStates[j])
        elseif opt.optim == 'adadelta' then
          adadelta_step(params[j], grad_params[j], layer_etas[j], optStates[j])
        elseif opt.optim == 'adam' then
          adam_step(params[j], grad_params[j], layer_etas[j], optStates[j])
        else
          params[j]:add(-opt.learning_rate, grad_params[j])
        end
        param_norm = param_norm + params[j]:norm()^2
      end
      param_norm = param_norm^0.5

      -- Bookkeeping
      num_words_target = num_words_target + batch_l*target_l
      num_words_source = num_words_source + batch_l*source_l
      train_nonzeros = train_nonzeros + nonzeros
      train_loss = train_loss + loss*batch_l

      local time_taken = timer:time().real - start_time
      if i % opt.print_every == 0 then
        local stats = string.format('Epoch: %d, Batch: %d/%d, Batch size: %d, LR: %.4f, ',
          epoch, i, data:size(), batch_l, opt.learning_rate)
        if opt.guided_alignment == 1 then
          stats = stats .. string.format('PPL: %.2f, PPL_CLL: %.2f, |Param|: %.2f, |GParam|: %.2f, ',
            math.exp(train_loss/train_nonzeros), math.exp(train_loss_cll/train_nonzeros), param_norm, grad_norm)
        else
          stats = stats .. string.format('PPL: %.2f, |Param|: %.2f, |GParam|: %.2f, ',
            math.exp(train_loss/train_nonzeros), param_norm, grad_norm)
        end
        stats = stats .. string.format('Training: %d/%d/%d total/source/target tokens/sec',
          (num_words_target+num_words_source) / time_taken,
          num_words_source / time_taken,
          num_words_target / time_taken)
        print(stats)
      end
      if i % 200 == 0 then
        collectgarbage()
      end
    end
    return train_loss, train_nonzeros
  end

  local total_loss, total_nonzeros, batch_loss, batch_nonzeros, total_loss_cll, batch_loss_cll
  for epoch = opt.start_epoch, opt.epochs do
    if opt.num_shards > 0 then
      total_loss = 0
      total_nonzeros = 0
      total_loss_cll = 0
      local shard_order = torch.randperm(opt.num_shards)
      for s = 1, opt.num_shards do
        local fn = train_data .. '.' .. shard_order[s] .. '.hdf5'
        print('loading shard #' .. shard_order[s])
        local shard_data = data.new(opt, fn)
        if opt.guided_alignment == 1 then
          batch_loss, batch_nonzeros, batch_loss_cll = train_batch(shard_data, epoch)
          total_loss_cll = total_loss_cll + batch_loss_cll
        else
          batch_loss, batch_nonzeros = train_batch(shard_data, epoch)
        end
        total_loss = total_loss + batch_loss
        total_nonzeros = total_nonzeros + batch_nonzeros
      end
    else
      total_loss, total_nonzeros = train_batch(train_data, epoch)
    end
    local train_score = math.exp(total_loss/total_nonzeros)
    print('Train', train_score)
    opt.train_perf[#opt.train_perf + 1] = train_score
    local score = eval(valid_data)
    opt.val_perf[#opt.val_perf + 1] = score
    if opt.optim == 'sgd' then --only decay with SGD
      decay_lr(epoch)
    end

    -- clean and save models
    local savefile = string.format('%s_epoch%.2f_%.2f.t7', opt.savefile, epoch, score)
    if epoch % opt.save_every == 0 then
      print('saving checkpoint to ' .. savefile)
      clean_layer(generator)
      torch.save(savefile, {{encoder, decoder, generator, encoder_bwd}, opt})
    end
  end
  -- save final model
  local savefile = string.format('%s_final.t7', opt.savefile)
  print('saving final model to ' .. savefile)
  torch.save(savefile, {{encoder:double(), decoder:double(), generator:double()}, opt})
end

function eval(data)
  encoder:evaluate()
  local nll = 0
  local total = 0
  for i = 1, data:size() do
    local d = data[i]
    local target, target_out, nonzeros, source = d[1], d[2], d[3], d[4]
    local batch_l, target_l, source_l = d[5], d[6], d[7]
    if opt.gpuid >= 0 and opt.gpuid2 >= 0 then
      cutorch.setDevice(opt.gpuid)
    end

    local preds = encoder:forward(source)

    local loss = criterion:forward(preds, target_out:view(-1))
    nll = nll + loss
    total = total + nonzeros
  end
  local valid = math.exp(nll / total)
  print("Valid", valid)
  collectgarbage()
  return valid
end

function get_layer(layer)
  if layer.name ~= nil then
    if layer.name == 'word_vecs_dec' then
      table.insert(word_vec_layers, layer)
    elseif layer.name == 'word_vecs_enc' then
      table.insert(word_vec_layers, layer)
    elseif layer.name == 'charcnn_enc' or layer.name == 'mlp_enc' then
      local p, gp = layer:parameters()
      for i = 1, #p do
        table.insert(charcnn_layers, p[i])
        table.insert(charcnn_grad_layers, gp[i])
      end
    end
  end
end

function main()
  -- parse input params
  opt = cmd:parse(arg)

  torch.manualSeed(opt.seed)

  if opt.gpuid >= 0 then
    print('using CUDA on GPU ' .. opt.gpuid .. '...')
    if opt.gpuid2 >= 0 then
      print('using CUDA on second GPU ' .. opt.gpuid2 .. '...')
    end
    require 'cutorch'
    require 'cunn'
    if opt.cudnn == 1 then
      print('loading cudnn...')
      require 'cudnn'
    end
    cutorch.setDevice(opt.gpuid)
    cutorch.manualSeed(opt.seed)
  end

  -- Create the data loader class.
  print('loading data...')
  if opt.num_shards == 0 then
    train_data = data.new(opt, opt.data_file)
  else
    train_data = opt.data_file
  end

  valid_data = data.new(opt, opt.val_data_file)
  print('done!')

  local max_source_l = train_data.source_l:max()
  local max_targ_l = train_data.target_l:max()

  print(string.format('Source vocab size: %d, Target vocab size: %d',
      valid_data.source_size, valid_data.target_size))
  opt.max_sent_l_src = valid_data.source:size(2)
  opt.max_sent_l_targ = valid_data.target:size(2)
  opt.max_sent_l = math.max(opt.max_sent_l_src, opt.max_sent_l_targ)
  if opt.max_batch_l == '' then
    opt.max_batch_l = valid_data.batch_l:max()
  end

  if opt.use_chars_enc == 1 or opt.use_chars_dec == 1 then
    opt.max_word_l = valid_data.char_length
  end
  print(string.format('Source max sent len: %d, Target max sent len: %d',
      valid_data.source:size(2), valid_data.target:size(2)))

  print(string.format('Number of additional features on source side: %d', valid_data.num_source_features))

  -- -- Enable memory preallocation - see memory.lua
  -- preallocateMemory(opt.prealloc)

  -- Build model
  -- block sizes are in format {nlayers, outputsize}
  local block_sizes = {
      {2, max_source_l*opt.word_vec_size/2},
      {2, max_source_l*opt.word_vec_size/4},
      {2, max_source_l*opt.word_vec_size/8},
      {2, max_source_l*opt.word_vec_size/16},
      {2, max_source_l*opt.word_vec_size/32}
  }
  if opt.train_from:len() == 0 then
    encoder = make_predictor(valid_data, opt, block_sizes, max_source_l, max_targ_l)
    --generator, criterion = make_generator(valid_data, opt)
    local w = torch.ones(valid_data.target_size)
    w[1] = 0
    criterion = nn.ClassNLLCriterion(w)
    criterion.sizeAverage = false
  else
    assert(false)
    assert(path.exists(opt.train_from), 'checkpoint path invalid')
    print('loading ' .. opt.train_from .. '...')
    local checkpoint = torch.load(opt.train_from)
    local model, model_opt = checkpoint[1], checkpoint[2]
    opt.num_layers = model_opt.num_layers
    opt.rnn_size = model_opt.rnn_size
    opt.input_feed = model_opt.input_feed or 1
    opt.attn = model_opt.attn or 1
    opt.brnn = model_opt.brnn or 0
    encoder = model[1]
    decoder = model[2]
    generator = model[3]
    if model_opt.brnn == 1 then
      encoder_bwd = model[4]
    end
    _, criterion = make_generator(valid_data, opt)
  end


  layers = {encoder}

  if opt.optim ~= 'sgd' then
    layer_etas = {}
    optStates = {}

    if opt.layer_lrs:len() > 0 then
      local stringx = require('pl.stringx')
      local lr_strings = stringx.split(opt.layer_lrs, ',')
      if #lr_strings ~= #layers then error('1 learning rate per layer expected') end
      for i = 1, #lr_strings do
        local lr = tonumber(stringx.strip(lr_strings[i]))
        if not lr then
          error(string.format('malformed learning rate: %s', lr_strings[i]))
        else
          layer_etas[i] = lr
        end
      end
    end

    for i = 1, #layers do
      layer_etas[i] = layer_etas[i] or opt.learning_rate
      optStates[i] = {}
    end
  end

  if opt.gpuid >= 0 then
    for i = 1, #layers do
      if opt.gpuid2 >= 0 then
        if i == 1 or i == 4 then
          cutorch.setDevice(opt.gpuid) --encoder on gpu1
        else
          cutorch.setDevice(opt.gpuid2) --decoder/generator on gpu2
        end
      end
      layers[i]:cuda()
    end
    if opt.gpuid2 >= 0 then
      cutorch.setDevice(opt.gpuid2) --criterion on gpu2
    end
    criterion:cuda()
  end

  -- these layers will be manipulated during training
  word_vec_layers = {}
  encoder:apply(get_layer)
  train(train_data, valid_data)
end

main()
