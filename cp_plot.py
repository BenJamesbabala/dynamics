import os
import sys
import plot_results

experiments = [
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_lrdecay_every10000',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_lrdecay_every5000',
                # 'balls_n2_t60_ex50000__balls_n2_t60_ex50000_batchnorm',
                # 'balls_n5_t60_ex50000__balls_n5_t60_ex50000_lrdecay_every5000',

                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_lrdecay_every2500',
                # 'balls_n5_t60_ex50000__balls_n5_t60_ex50000_lrdecay_every2500',
                # 'balls_n6_t60_ex50000__balls_n6_t60_ex50000_lrdecay_every2500',
                # 'balls_n7_t60_ex50000__balls_n7_t60_ex50000_lrdecay_every2500',
                # 'balls_n8_t60_ex50000__balls_n8_t60_ex50000_lrdecay_every2500',
                # 'balls_n9_t60_ex50000__balls_n9_t60_ex50000_lrdecay_every2500',
                # 'balls_n10_t60_ex50000__balls_n10_t60_ex50000_lrdecay_every2500',


                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_modelind',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_modelcat_lr3e-5',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_modelcat_lr3-e5_lineardecoder',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_modelind_lineardecoder',
                # 'balls_n3_t60_ex50000,balls_n4_t60_ex50000__balls_n5_t60_ex50000',
                # 'balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n3_t60_ex50000',
                # 'balls_n5_t60_ex50000,balls_n3_t60_ex50000__balls_n4_t60_ex50000',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lr3e-3',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lr7e-4',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lr5e-4',

                # 'balls_n3_t60_ex50000,balls_n4_t60_ex50000__balls_n5_t60_ex50000_modelcat_lr3e-05',
                # 'balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n3_t60_ex50000_modelcat_lr3e-05',
                # 'balls_n5_t60_ex50000,balls_n3_t60_ex50000__balls_n4_t60_ex50000_modelcat_lr3e-05',

                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecayevery5000',


                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers3_lr0.0001_lrdecay_every2500',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers4_lr0.0001_lrdecay_every2500',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers3_lr0.0001_lrdecay_every5000',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers4_lr0.0001_lrdecay_every5000',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers3_lr0.001_lrdecay_every2500',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers4_lr0.001_lrdecay_every2500',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers3_lr0.001_lrdecay_every5000',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers4_lr0.001_lrdecay_every5000',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers3_lr0.005_lrdecay_every2500',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers4_lr0.005_lrdecay_every2500',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers3_lr0.005_lrdecay_every5000',
                # 'balls_n3_t60_ex50000_m__balls_n3_t60_ex50000_m_lrdecay_every2500_layers4_lr0.005_lrdecay_every5000',

                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_num_past10',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_num_past9',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_num_past8',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_num_past7',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_num_past6',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_num_past5',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_num_past4',
                # 'balls_n3_t60_ex50000__balls_n3_t60_ex50000_num_past3',

                # all of the above have been plotted after the experiments finished or ran out of time. Possibly not simulated.

                # bffobj initial test
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers1_nbrhd_lr0.0003_modelbffobj', # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers1_nbrhd_lr0.001_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers1_nbrhd_lr0.003_modelbffobj',  # killed
                'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers2_nbrhd_lr0.0003_modelbffobj',  
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers2_nbrhd_lr0.001_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers2_nbrhd_lr0.003_modelbffobj',  # killed
                'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',  
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers3_nbrhd_lr0.001_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers3_nbrhd_lr0.003_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers1_lr0.0003_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers1_lr0.001_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers1_lr0.003_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers2_lr0.0003_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers2_lr0.001_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers2_lr0.003_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers3_lr0.0003_modelbffobj', # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers3_lr0.001_modelbffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers3_lr0.003_modelbffobj',  # killed

                # ffobj with nbrhd initial test'
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers1_nbrhd_lr0.0003_modelffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers1_nbrhd_lr0.001_modelffobj',  # killed
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers1_nbrhd_lr0.003_modelffobj',  # killed
                'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers2_nbrhd_lr0.0003_modelffobj',
                'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers2_nbrhd_lr0.001_modelffobj',
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers2_nbrhd_lr0.003_modelffobj',  # killed
                'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers3_nbrhd_lr0.0003_modelffobj',
                'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers3_nbrhd_lr0.001_modelffobj',
                # 'balls_n4_t60_ex50000__balls_n4_t60_ex50000_layers3_nbrhd_lr0.003_modelffobj',  # killed

                # bffobj generalization test
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000__balls_n5_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',
                'balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n3_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',
                'balls_n5_t60_ex50000,balls_n3_t60_ex50000__balls_n4_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',

                # generalization test 2
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n7_t60_ex50000_layers3_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000_layers3_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n8_t60_ex50000_layers3_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000,balls_n7_t60_ex50000_layers3_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000,balls_n8_t60_ex50000_layers3_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000,balls_n7_t60_ex50000,balls_n8_t60_ex50000_layers3_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n7_t60_ex50000,balls_n8_t60_ex50000_layers3_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n7_t60_ex50000_layers3_nbrhd_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000_layers3_nbrhd_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n8_t60_ex50000_layers3_nbrhd_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n7_t60_ex50000,balls_n8_t60_ex50000_layers3_nbrhd_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000,balls_n7_t60_ex50000_layers3_nbrhd_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000,balls_n7_t60_ex50000,balls_n8_t60_ex50000_layers3_nbrhd_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000,balls_n8_t60_ex50000_layers3_nbrhd_lr0.0003_modelffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n7_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n8_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000,balls_n7_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000,balls_n8_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n7_t60_ex50000,balls_n8_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',
                'balls_n3_t60_ex50000,balls_n4_t60_ex50000,balls_n5_t60_ex50000__balls_n6_t60_ex50000,balls_n7_t60_ex50000,balls_n8_t60_ex50000_layers3_nbrhd_lr0.0003_modelbffobj',
                ]

# specify paths
out_root = 'opmjlogs'
in_root = '/om/user/mbchang/physics/lua/logs'
copy_prefix = 'rsync -avz --exclude \'*.t7\' mbchang@openmind7.mit.edu:'
remote_prefix = '/om/user/mbchang/physics/lua/logs/'

# copy
if len(experiments) > 1:
    remote_paths = remote_prefix + '\{' + ','.join(['\\"' + e + '\\"' for e in experiments]) + '\} '
    command = copy_prefix + remote_paths + out_root
else:
    remote_paths = remote_prefix + experiments[0] + ' '
    command = copy_prefix + remote_paths + out_root + '/'

response = raw_input('Running command:\n\n' + command + '\n\nProceed?[y/n]')
if response == 'y':
    os.system(command)
elif response != 'n':
    response = raw_input('Running command:\n\n' + command + '\nProceed?[y/n]')
else:
    print 'Not running command.'
    sys.exit(0)

# plot
for experiment_folder in experiments:
    try:
        experiment_folder = os.path.join(out_root, experiment_folder)
        # command = 'th plot_results.lua -hid -infolder ' + experiment_folder
        command = 'th plot_results.lua -infolder ' + experiment_folder
        print command
        os.system(command)
        # print 'plot hidden state'
        # plot_results.plot_hid_state(experiment_folder)  # TODO! check if filepath is correct
    except KeyboardInterrupt:
        sys.exit(0)
