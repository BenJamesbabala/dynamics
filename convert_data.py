import os, sys, shutil
import cPickle as pickle
import time
import string
import random
from numpy import *
import numpy as np
import pprint
import re
import h5py

# PyGame Constants Comment out for openmind
import pygame
from pygame.locals import *
from pygame.color import THECOLORS
import particle

# Local imports
from context_particles import *
from utils import *

G_num_videos = 500.0
G_num_timesteps = 400.0
G_num_objects = 6 + 5 - 1  # 6 particles + 5 goos - 1 for the particle you are conditioning on
G_SUBSAMPLE = 5  # 5 is a good rate

def convert_file(path, subsample):
    """
        input
            :type path: string
            :param path: path of particular instance of a configuration of a world file
        output
            write a hdf5 file of data
    """
    fileobject = open(path)
    data = fileobject.readlines()

    ## Note that the input file has to be 'comma-ed' and the brackets fixed, since Scheme gives us data without commas.
    configuration   = eval(fixInputSyntax(data[0]))
    forces          = np.array(configuration[0])
    particles       = [{attr[0]: attr[1] for attr in p} for p in configuration[1]]  # configuration is what it originally was
    goos            = np.array(configuration[2])
    initial_pos     = np.array(eval(fixInputSyntax(data[1])))  # (numObjects, [px, py])
    initial_vel     = np.array(eval(fixInputSyntax(data[2])))  # (numObjects, [vx, vy])
    observedPath    = np.array(eval(fixInputSyntax(data[3])))  # (numSteps, [pos, vel], numObjects, [x, y])

    # subsample
    observedPathsub = observedPath[::subsample,:,:,:]
    print 'Total timesteps:', observedPath.shape[0], 'After subsampling', G_SUBSAMPLE, ':', observedPathsub.shape[0]

    return particles, goos, observedPathsub

def ltrb2xywh(boxes):
    """
        boxes: np array of (num_boxes, [left, top, right, bottom])
        out: np array of (num_boxes, [cx, cy, width, height])
    """
    for i in xrange(len(boxes)):
        box = boxes[i]
        left, top, right, bottom = box[:]
        w = right - left  # right > left
        h = bottom - top  # bottom > top
        assert w > 0 and h > 0
        cx = (right + left)/2
        cy = (bottom + top)/2
        boxes[i] = np.array([cx, cy, w, h])
    return boxes

def crop_to_window(boxes):
    """
        boxes: np array of (num_boxes, [left, top, right, bottom])
        crops these dimensions so that they are inside the window dimensions
    """
    for i in xrange(len(boxes)):
        box = boxes[i]
        left, top, right, bottom = box[:]
        new_left = max(0, left)
        new_top = max(0, top)
        new_right = min(G_w_width, right)
        new_bottom = min(G_w_height, bottom)
        boxes[i] = np.array([new_left, new_top, new_right, new_bottom])
    return boxes

def construct_example(particles, goos, observedPath, starttime, windowsize):
    """
        input
            :particles: list of dictionaries (each dictionary is a particle)
                dict keys are ['elastic', 'color', 'field-color', 'mass', 'field-strength', 'size']
            :goos: list of lists
                each list is [[left, top], [right, bottom], gooStrength, color]
            :observedPath: (numSteps, [pos, vel], numObjects, [x, y])
            :starttime: start time of the example (inclusive)
            :windowsize: how many time steps this example will cover (10 in 10 out has win size of 20)

        constraints
            :starttime + windowsize < 400

        output
            :path_slice: np array (numObjects, numSteps, [px, py, vx, vy, [onehot mass]])
            :goos: np array [cx, cy, width, height, [onehot goo strength], objectid]
            :mask? TODO

        masses: [0.33, 1.0, 3.0]
        gooStrength: [0, -5, -20]

        object id: 1 if particle, 0 if goo

        For goos:  crop --> ltrb2xywh --> normalize
        For particles:
    """
    assert starttime + windowsize <= len(observedPath)  # 400 is the total length of the video

    path_slice = observedPath[starttime:starttime+windowsize]  # (windowsize, [pos, vel], numObjects, [x,y])

    # turn it into (numObjects, numSteps, [pos, vel], [x,y])
    path_slice = np.transpose(path_slice, (2,0,1,3))

    # turn it into (numObjects, numSteps, [px, py, vx, vy])
    path_slice = path_slice.reshape(path_slice.shape[0], path_slice.shape[1], path_slice.shape[2]*path_slice.shape[3])
    num_objects, num_steps = path_slice.shape[:2]

    # get masses
    masses = tuple(np.array([p['mass'] for p in particles]) for i in xrange(num_steps))
    masses = np.column_stack(masses)  # (numObjects, numSteps)
    masses = num_to_one_hot(masses, G_mass_values)  # (numObjects, numSteps, 3)

    # turn it into (numObjects, numSteps, [px, py, vx, vy, [one-hot-mass]]) = (numObjects, numSteps, 7)
    path_slice = np.dstack((path_slice, masses))
    path_slice = np.dstack((path_slice, np.ones((num_objects, num_steps))))  # object ids: particle = 1
    path_slice[:,:,:2] = path_slice[:,:,:2]/G_w_width  # normalize position
    assert np.all(path_slice[:,:,:2] >= 0) and np.all(path_slice[:,:,:2] <= 1)
    path_slice[:,:,2:4] = path_slice[:,:,2:4]/G_max_velocity  # normalize velocity
    assert path_slice.shape == (num_objects, num_steps, 8)

    goos = np.array([[goo[0][0],goo[0][1], goo[1][0], goo[1][1], goo[2]] for goo in goos])  # (numGoos, [left, top, right, bottom, gooStrength])
    num_goos = goos.shape[0]

    if num_goos > 0:
        # crop --> ltrb2xywh --> normalize
        goo_strengths = goos[:,-1]
        goo_strengths = num_to_one_hot(goo_strengths, G_goo_strength_values)  # (numGoos, 3)
        goos = np.concatenate((goos[:,:-1], goo_strengths), 1)  # (num_goos, 7)  one hot
        goos = np.concatenate((goos, np.zeros((num_goos,1))), 1)  # (num_goos, 8)  object ids: goo = 0
        goos[:,:4] = crop_to_window(goos[:,:4])  # crop so that dimensions are inside window
        goos[:,:4] = ltrb2xywh(goos[:,:4])  # convert [left, top, right, bottom] to [cx, cy, w, h]
        goos[:,:4] = goos[:,:4]/G_w_width  # normalize coordinates
        assert np.all(goos[:,:4] >= 0) and np.all(goos[:,:4] <= 1)
        assert goos.shape == (num_goos, 8)

    path_slice = np.asarray(path_slice, dtype=np.float64)
    goos = np.asarray(goos, dtype=np.float64)

    return (path_slice, goos)

def subsample_range(range_length, windowsize, num_samples):
    """
        range_length: int, from 0 to this number
        rate:

    """
    if num_samples == 1:
        return np.array([0])
    else:
        last_possible_index = range_length - windowsize
        rate = int((last_possible_index)/(num_samples-1))
        subsampled_range = np.arange(last_possible_index+1)[0::rate][:num_samples]
        assert(len(subsampled_range)==num_samples)
        return subsampled_range

def get_examples_for_video(video_path, num_samples, windowsize, contiguous):
    """
        Returns a list of examples for this particular video

        input
            :video_path: str, full path to the "video"file
            :num_samples: int, number of samples from this video to get
            :windowsize: k-in-m-out means the windowsize is k+m

        output
            :list of randomly chosen examples in this video
                - each example is a list of two np arrays: [path_slice, goos]
                - number of examples is dictated by num_samples

            # stack(video_sample_particles): (num_samples_in_video, num_objects, windowsize, 5)
            # stack(video_sample_goos): (num_samples_in_video, num_goos, 5)
    """
    particles, goos, observedPath = convert_file(video_path, G_SUBSAMPLE)

    # sample randomly
    if contiguous:
        samples_idxs = subsample_range(len(observedPath), windowsize, num_samples)
    else:
        samples_idxs = np.random.choice(range(len(observedPath)-windowsize), num_samples, replace=False)  # indices
    print 'video', video_path[video_path.rfind('/')+1:]
    print 'video samples:', samples_idxs, type(samples_idxs)

    # separate here!
    video_sample_particles = []
    video_sample_goos = []
    for starttime in samples_idxs:
        sample_particles, sample_goos = construct_example(particles, goos, observedPath, starttime, windowsize)
        video_sample_particles.append(sample_particles)
        video_sample_goos.append(sample_goos)

    # stack(video_sample_particles): (num_samples_in_video, num_objects, windowsize, 5)
    # stack(video_sample_goos): (num_samples_in_video, num_goos, 5)

    return stack(video_sample_particles), stack(video_sample_goos)

def get_examples_for_config(config_path, config_sample_idxs, num_samples_per_video, windowsize, contiguous):
    """
        Returns a list of examples for this particular config

        input
            :config_path: str, full path to the folder for this configuration
                a configuration will be something like world_m1_np=2_ng=3
            :config_sample_idxs: np array of indices of videos in the folder config_path
                config_sample_idxs were randomly chosen from the parent function
            :num_samples_per_video: int, number of samples we want to sample from each video
            :windowsize: k-in-m-out means the windowsize is k+m

        output
            :list of randomly chosen examples in randomly chosen videos
                - each example is a list of two np arrays: [path_slice, goos]
                - number of examples is dictated by num_samples

            # config_sample_particles: (num_samples_in_config, num_objects, windowsize, 5)
            # config_sample_goos: (num_samples_in_config, num_goos, 5)
    """
    for v in os.listdir(config_path):
        assert '.ss' in v # make sure videos are valid

    config_sample_particles = []
    config_sample_goos = []
    print 'config samples idxes:', np.array(os.listdir(config_path))[config_sample_idxs]
    for video in np.array(os.listdir(config_path))[config_sample_idxs]:
        video_sample_particles, video_sample_goos = get_examples_for_video(os.path.join(config_path, video), num_samples_per_video, windowsize, contiguous)
        config_sample_particles.append(video_sample_particles)
        config_sample_goos.append(video_sample_goos)

    # Concatenate along first dimension
    config_sample_particles = np.vstack(config_sample_particles)
    config_sample_goos = np.vstack(config_sample_goos)

    # config_sample_particles: (num_samples_in_config, num_objects, windowsize, 5)
    # config_sample_goos: (num_samples_in_config, num_goos, 5)

    return config_sample_particles, config_sample_goos

def create_datasets(data_root, num_train_samples_per, num_val_samples_per, num_test_samples_per, windowsize, contiguous, filterconfig):
    """
        ACTUALLY IT IS 36 configs! (1-6)p, (0-5)g

        orig: 4 worlds * 30 configs * 500 videos * 400 timesteps * 1-6 particles

        subsampled: 4 worlds * 30 configs * 500 videos * 80 timesteps * 1-6 particles = 28,800,000
            let's say on average there are 3 particles

        computation: 4 worlds * 30 configs * 3 particles * (x per config * y per video)

        Note that you have 339,380 parameters with 4 layers, so you need about 60,000 training, 10,000 validation, 10,000 test

        TODO: make more flexible

        samples_per: (per_config, per_video)

        filter: a keyword substring that is in the world config that you want.
                empty string if you want all the data

        # Train: 50 5 = 250 --> 4 worlds * 30 configs * 3 particles * 50 videos * 5 timesteps = 90,000
        # Val: 10 5 = 50 --> 4 worlds * 30 configs * 3 particles * 10 videos * 5 timesteps = 18,000
        # Test: 10 5 = 50 --> 4 worlds * 30 configs * 3 particles * 10 videos * 5 timesteps = 18,000

        # the directory hierarchy is
            data_root
                configs
                    videofiles

        Train, val, test are split on the video level, not within the video
    """
    def get_samples_per(samples_per_tuple):
        return {'per_config': samples_per_tuple[0], 'per_video': samples_per_tuple[1]}

    sp = {'train': get_samples_per(num_train_samples_per),
          'val': get_samples_per(num_val_samples_per),
          'test': get_samples_per(num_test_samples_per)}

    # Number of Examples
    num_world_configs = len(os.listdir(data_root))  # assume the first world in data_root is representative
    print "Number of world configs", num_world_configs
    print 'Number of train examples:', num_world_configs * (sp['train']['per_config'] * sp['train']['per_video'])# ** 2)
    print 'Number of validation examples:', num_world_configs * (sp['val']['per_config'] * sp['val']['per_video'])# ** 2)
    print 'Number of test examples:', num_world_configs * (sp['test']['per_config'] * sp['test']['per_video'])# ** 2)

    # Number of total videos to sample per config
    num_sample_videos_per_config = sp['train']['per_config'] + sp['val']['per_config'] + sp['test']['per_config']  # 30 + 10 + 10

    # Containers
    trainset    = {}  # a dictionary of train examples, with 120 keys for world-config
    valset      = {}  # a dictionary of val examples, with 120 keys for world-config
    testset     = {}  # a dictionary of test examples, with 120 keys for world-config

    # data_root = '/Users/MichaelChang/Documents/SuperUROPlink/Code/tomer_pe/physics-andreas/saved-worlds/'
    for world_config in os.listdir(data_root):
        print world_config
        if filterconfig in world_config:  # TAKEOUT
            print '\n########################################################################'
            print 'WORLD CONFIG:', world_config
            config_path = os.path.join(data_root, world_config)
            num_videos_per_config = len(os.listdir(config_path))

            # sample random videos in the config. Here is where we sample number of videos per config. Don't care if in train, val, or test
            sampled_videos_idxs = np.random.choice(range(num_videos_per_config), num_sample_videos_per_config, replace=False)

            # split into train and val and test. This is where we split train, val, set within the config
            train_sample_idxs   = sampled_videos_idxs[:sp['train']['per_config']]  # first part
            val_sample_idxs     = sampled_videos_idxs[sp['train']['per_config']:sp['train']['per_config']+sp['val']['per_config']]  # middle part
            test_sample_idxs    = sampled_videos_idxs[sp['train']['per_config']+sp['val']['per_config']:]  # last part

            # check sizes. We defined the number of videos sampled will also be the number of samples in that video
            assert len(train_sample_idxs) == sp['train']['per_config']
            assert len(val_sample_idxs) == sp['val']['per_config']
            assert len(test_sample_idxs) == sp['test']['per_config']

            # add to dictionary. The values returned by get_examples_for_config are tuples!
            # Here sample within config, but pass num_samples_within_video here for use that will be used get_examples_for_video
            print '\nTRAINSET'
            trainset[world_config]    = get_examples_for_config(config_path, train_sample_idxs, sp['train']['per_video'], windowsize, contiguous)
            print '\nVALSET'
            valset[world_config]      = get_examples_for_config(config_path, val_sample_idxs, sp['val']['per_video'], windowsize, contiguous)
            print '\nTESTSET'
            testset[world_config]     = get_examples_for_config(config_path, test_sample_idxs, sp['test']['per_video'], windowsize, contiguous)

    # flatten the datasets
    trainset = flatten_dataset(trainset)
    valset = flatten_dataset(valset)
    testset = flatten_dataset(testset)

    # save each dictionary as a separate h5py file
    return trainset, valset, testset

def flatten_dataset(dataset):
    flattened_dataset = {}
    for k in dataset.keys():
        flattened_dataset[k+'particles'] = dataset[k][0]  # (num_samples, num_particles, windowsize, [px, py, vx, vy, [onehot mass]])
        flattened_dataset[k+'goos'] = dataset[k][1]  # (num_samples, num_goos, [cx, cy, width, height, [onehot goostrength]])
        mask = np.zeros(G_num_objects)  # max number of objects is 6 + 5, so mask is 10
        num_particles = dataset[k][0].shape[1]
        num_goos = dataset[k][1].shape[1]
        # if there are four particles and 2 goos , then mask is [0, 0, 0, 0, 1, 0, 0, 0, 0, 0]
        if num_particles + num_goos == 1:  # this means context is empty
            mask[0] = 1
        else:
            mask[num_particles + num_goos - 1 - 1] = 1  # first -1 for 0-indexing, second -1 because we condition on one particle
        flattened_dataset[k+'mask'] = mask
    return flattened_dataset

def save_all_datasets(dryrun):
    """
    let's say on average there are 3 particles

    Full: 4 worlds * 36 configs * 500 videos * 400 timesteps * 3 particles = 86,400,000
    Subsampled: 4 worlds * 36 configs * 500 videos * 80 timesteps * 3 particles = 17,280,000
    Computation: 4 worlds * 36 configs * 3 particles * (x per config * y per video)


    Subset of 2 particles:
        4 worlds * 6 configs * 500 videos * 80 timesteps * 2 particles = 17,280,000
        Computation: 4 worlds * 6 configs * 2 particles * (x per config * y per video)

        80 timesteps --> 12 samples, with winsize = 20: about 1 sample every 5
        500 videos --> 160 samples
        Train: 4 * 6 * 2 * 160 * 12 = 92,160
        Test: 4 * 6 * 2 * 20 * 12 = 11,520

    Note that you have 339,380 parameters with 4 layers, so you need about 60,000 training, 10,000 validation, 10,000 test

    Although, it turns out that I ended up sampling 13 samples per video. TODO FIX
    """
    dataset_files_folder = '/om/data/public/mbchang/physics-data/4'
    if not os.path.exists(dataset_files_folder): os.mkdir(dataset_files_folder)
    data_root = '/om/data/public/mbchang/physics-data/data'
    windowsize = 20  # 2  -- TODO 1in1out
    num_train_samples_per = (400, 60)  # 3
    num_val_samples_per = (50, 60)  # 1
    num_test_samples_per = (50, 60)  # 1
    contiguous = True

    # dataset_files_folder = 'hey'
    # data_root = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/data/physics-data'
    # windowsize = 2  # 20
    # num_train_samples_per = (32, 60)  # 30
    # num_val_samples_per = (32, 60)  # 10
    # num_test_samples_per = (32, 60)  # 10
    # contiguous = True

    trainset, valset, testset = create_datasets(data_root,
                                                num_train_samples_per,
                                                num_val_samples_per,
                                                num_test_samples_per,
                                                windowsize,
                                                contiguous,
                                                'np=2_ng=0')

    # # save
    if not dryrun:
        print '\n########################################################################'
        print 'SAVING'
        save_dict_to_hdf5(trainset, 'trainset', dataset_files_folder)
        save_dict_to_hdf5(valset, 'valset', dataset_files_folder)
        save_dict_to_hdf5(testset, 'testset', dataset_files_folder)
    print '####################################################################'
    print 'Dataset_files_folder:', dataset_files_folder
    print 'Trainset:', num_train_samples_per[0], 'examples per config', num_train_samples_per[1], 'examples per video'
    print 'Valset:', num_val_samples_per[0], 'examples per config', num_val_samples_per[1], 'examples per video'
    print 'Testset:', num_test_samples_per[0], 'examples per config', num_test_samples_per[1], 'examples per video'
    print 'Windowsize:', windowsize
    print 'Contiguous:', contiguous

def fixInputSyntax(l):
    """
    # helper function for putting commas in the
    # files we get from Church, which don't contain
    # them, a fact Python does not care for.
    # also changes lists () to tuples [], which is
    # important for indexing and other handling
    """
    # remove multiple contiguous whitespaces
    l = re.sub( '\s+', ' ', l ).strip()

    l = re.sub(r'([a-z])(\))', r'\1"\2', l)  # put a quotation after a word before parentheses
    l = re.sub(r'([a-z])(\s)', r'\1"\2', l)  # put a quotation after a word before space
    l = re.sub(r'(\()([a-z])', r'\1"\2', l)  # put a quotation before a word after parentheses
    l = re.sub(r'(\s)([a-z])', r'\1"\2', l)  # put a quotation before a word after space
    l = re.sub(r'(\")(\d+\.*\d*)(\")', r'\2', l)  # remove quotations around numbers

    # convert to list representation with commas
    l = l.replace(' ', ',').replace('(', '[').replace(')', ']')

    # find index of first "'" and index of last ',' to get list representation
    begin = l.find("'")+1
    end = l.rfind(",")
    l = l[begin:end]

    # remove all "'"
    l = l.replace("'","")

    return l

def getParticleCoords(observedPath,pindex):
    """
        pindex is the index of the particle
        helper function, takes in data and
        a particle index, and gets the coords
        of that particle.

        This is necessary because the data
        is an aggregate of particle paths
        and sometimes we just want a specific path.
        That is, we want to go from:
        ((pos0_t1, pos1_t1), (pos0_t2, pos1_t2),...)
        to:
        ((pos0_t1), (pos0_t2),...)
        so here pindex is 0
    """
    return observedPath[:,0,pindex,:]

def render_from_scheme_output(path, framerate, movie_folder, movieName, save):
    particles, goos, observedPath = convert_file(path, G_SUBSAMPLE)
    render(goos, particles, observedPath, framerate, movie_folder, movieName, save, 0)

def render(goos, particles, observed_path, framerate, movie_folder, movieName, save, start_frame):
    """
        input

            goos
                something like
                [[[511, 289] [674, 422] 0 'darkmagenta']
                 [[217, 352] [327, 561] 0 'darkmagenta']
                 [[80, 155] [205, 299] 0 'darkmagenta']
                 [[530, 393] [617, 598] 0 'darkmagenta']
                 [[171, 36] [389, 149] 0 'darkmagenta']]

            particles
                list of something like
                {'color': 'red',
                  'field-color': 'black',  # we hardcode this
                  'mass': 1.0,
                  'size': 40.0},  # we hardcode this

            observedPath    = (winsize, [pos, vel], numObjects, [x, y])

            framerate: frames per second

            movie_folder: folder to save movie in

            movieName: name of the movie

            save: True if want to save pngs

            startFrame: int, framenumber you want to start on
    """
    ## Get the data.
    ## data is the x-y coordinates of the particles over times, organized as (STEP0, STEP1, STEP2...)
    ## Where each 'Step' consists of (PARTICLE0, PARTICLE1...)
    ## and each PARTICLE consists of (x, y).
    ## So, for example, in order to get the x-coordinates of particle 1 in time-step 3, we would do data[3][1][0]

    WINSIZE = 640,480
    pygame.init()
    screen = pygame.display.set_mode(WINSIZE)
    clock = pygame.time.Clock()
    screen.fill(THECOLORS["white"])
    pygame.draw.rect(screen, THECOLORS["black"], (3,1,639,481), 45)

    # Set up masses, their number, color, and size
    numberOfParticles   = len(particles)
    sizes               = [p['size'] for p in particles]
    particleColors      = [p['color'] for p in particles]
    fieldColors         = [p['field-color'] for p in particles]

    ## Set up the goo patches, if any
    ## (a goo is list of [[left top], [right bottom], resistence, color])
    gooList = goos

    ## Set up obstacles, if any
    ## (an obstacle is list of [ul-corner, br-corner, color])
    obstacleColor = "black"
    obstacleList = [] #fixedInput[3]

    ## Create particle objects using a loop over the particle class
    for particleIndex in range(numberOfParticles):
        pcolor = THECOLORS[particleColors[particleIndex]]
        fcolor = THECOLORS[fieldColors[particleIndex]]
        exec('particle' + str(particleIndex) + \
             ' = particle.Particle( screen, (sizes[' + str(particleIndex) + \
             '],sizes[' + str(particleIndex) + ']), getParticleCoords(observed_path,' + \
             str(particleIndex) + '), THECOLORS["white"],' + str(pcolor)+ ',' + str(fcolor) + ')')

    movieFrame = 0
    madeMovie = False
    frameAllocation = 4
    basicString = '0'*frameAllocation

    maxPath = len(observed_path)

    done = False
    while not done:
        # change the object of interest to pink if we are predicting
        if start_frame > 0:
            for i in range(numberOfParticles):
                if (eval('particle' + str(i) + ".fieldcolor == THECOLORS['green']")):
                    exec('particle' + str(i) + ".fieldcolor = THECOLORS['hotpink1']")


        clock.tick(float(framerate))
        screen.fill(THECOLORS["white"])
        pygame.draw.rect(screen, THECOLORS["black"], (3,1,639,481), 45)  # draw border


        # fill the background with goo, if there is any
        if len(gooList) > 0:
            for goo in gooList:
                pygame.draw.rect(screen, THECOLORS[goo[3]], \
                     Rect(goo[0][0], goo[0][1], abs(goo[1][0]-goo[0][0]), abs(goo[1][1]-goo[0][1])))


        # fill in the obstacles, if there is any
        if len(obstacleList) > 0:
            for obstacle in obstacleList:
                pygame.draw.rect(screen, THECOLORS[obstacle[2]], \
                     Rect(obstacle[0][0], obstacle[0][1], \
                      abs(obstacle[1][0]-obstacle[0][0]), abs(obstacle[1][1]-obstacle[0][1])))

        # Drawing handled with exec since we don't know the number of particles in advance:
        for i in range(numberOfParticles):
            if (eval('particle' + str(i) + '.frame >=' + str(maxPath-1))):
                exec('particle' + str(i) + '.frame = ' + str(maxPath-1))
            exec('particle' + str(i) + '.draw()')

        pygame.draw.rect(screen, THECOLORS["black"], (3,1,639,481), 45)  # draw border

        # Drawing finished this iteration?  Update the screen
        pygame.display.flip()

        # make movie
        if movieFrame <= (len(observed_path)-1):
            imageName = basicString[0:len(basicString) - \
                            len(str(movieFrame+start_frame))] + \
                            str(movieFrame+start_frame)
            imagefile = movie_folder + "/" + movieName + '-' + imageName + ".png"
            print imagefile
            pygame.image.save(screen, imagefile)
            movieFrame += 1
        elif movieFrame > (len(observed_path)-1):
            done = True

def create_all_videos(root, movie_root):
    """
        root: something like /om/user/mbchang/physics-data/data
            or /Users/MichaelChang/Documents/SuperUROPlink/Code/data/physics-data
        movei_root: folder you want to save the movies in

    """
    framerate = 10
    for folder in os.listdir(root):
        if folder[0] != '.':
            folder_abs_path = os.path.join(root, folder)  # each folder here is a world configuration
            world_config_folder = os.path.join(movie_root, folder)
            if not os.path.isdir(world_config_folder): os.mkdir(world_config_folder)
            for worldfile in os.listdir(folder_abs_path):  # each worldfile is an instance of the world configuration = movie
                path = os.path.join(folder_abs_path, worldfile)
                movieName = worldfile[:worldfile.rfind('.ss')]  # each world file is a particular movie
                movie_folder = os.path.join(world_config_folder, movieName)
                if not os.path.isdir(movie_folder): os.mkdir(movie_folder)
                render_from_scheme_output(path=path, framerate=framerate, movie_folder = movie_folder, movieName = movieName)

def separate_context(context, config):
    """
    context:    (num_samples, G_num_objects, winsize/2, 8)
        8: [[4 number description], [3 number type], [1 number id]]
    config: something like: worldm1_np=1_ng=1

    Return
        other: (num_samples, num_other_particles, winsize/2, 8)
        goos: (num_samples, num_goos, winsize/2, 8)

        Note that num_other_particles and num_goos could be 0
    """
    # find number of particles
    start = config.find('_np=')+len('_np=')
    end = start + config[start:].find('_ng=')
    num_particles = int(config[start:end])
    num_other = num_particles - 1

    # find number of goos
    start = config.find('_ng=')+len('_ng=')
    num_goos = int(config[start:])

    print 'num_particles', num_particles
    print 'num_goos', num_goos
    print 'num_other', num_other

    # Thus, the RNN should only run for num_particles + num_goos iterations
    if num_particles + num_goos != G_num_objects+1:  # TODO: shouldn't this be G_num_objects + 1?
        begin_zeros_here = num_other + num_goos
        assert(not np.any(context[:, begin_zeros_here:,:,:]))  # everything after

    begin_goos_here = begin_zeros_here - num_goos
    assert num_other == begin_goos_here

    # other_particles should be: (num_samples, num_other, winsize/2, 8)
    other = context[:, :begin_goos_here, :, :]  # take care of the case when other is nothing

    # goos should be: (num_samples, num_goos, winsize/2, 8)
    goos = context[:,begin_goos_here:begin_zeros_here,:,:]

    # as a check, the object ids for goos should be 0 and for other should be 1
    # works as well if there are no other or no goos
    assert np.all(other[:,:,:,-1]== 1)  # all other should have id of 1
    assert np.all(goos[:,:,:,-1] == 0)  # all goos should have id of 0

    return other, goos

def recover_goos(goos):
    """
        goos: (num_samples, num_goos, winsize/2, 8)

        The winsize/2 dimension doesn't matter, so goos[:,:,0,:] should
        equal goos[:,:,1,:], etc

        To render one example, look at one sample in all_sample_goos

        all_sample_goos:
            list over samples of something like the following list,
                which is named goos_in_this_sample

                [[[511, 289] [674, 422] 0 'darkmagenta']
                 [[217, 352] [327, 561] 0 'darkmagenta']
                 [[80, 155] [205, 299] 0 'darkmagenta']
                 [[530, 393] [617, 598] 0 'darkmagenta']
                 [[171, 36] [389, 149] 0 'darkmagenta']]
    """
    unduplicated_goos = goos[:,:,0,:]  # (num_samples, num_goos, 8)

    # Double check that the winsize/2 dimension doesn't matter
    for i in range(1, goos.shape[2]):
        assert np.allclose(unduplicated_goos, goos[:,:,i,:])

    all_sample_goos = []
    for s in xrange(unduplicated_goos.shape[0]):  # iterate over samples
        goos_in_this_sample = []
        for g in xrange(unduplicated_goos.shape[1]):  # iterate over goos
            goo = Context_Goo(unduplicated_goos[s,g,:]).format()
            goos_in_this_sample.append(goo)
        all_sample_goos.append(goos_in_this_sample)

    return all_sample_goos

def recover_particles(this, other):
    """
        Just recovers the particle attributes not the paths

        this:     (num_samples, winsize/2, 8)
        other:    (num_samples, num_other_particles, winsize/2, 8)

        this:
                {'color': 'red',
                  'field-color': 'black',  # we hardcode this
                  'mass': 1.0,
                  'size': 40.0}
        other:
            list of
                {'color': 'red',
                  'field-color': 'black',  # we hardcode this
                  'mass': 1.0,
                  'size': 40.0}
    """

    def hardcode_attributes(particle_dict, pred=False):
        particle_dict['field-color'] = 'green' if pred else 'black'
        particle_dict['size'] = 40.0
        return particle_dict

    samples = []  # each element is a list of particles for that sample
    for s in xrange(this.shape[0]): # iterate over samples
        sample_particles = []
        this_particle = hardcode_attributes(Context_Particle(this[s,:,:]).to_dict(), True)
        sample_particles.append(this_particle)

        for o in xrange(other.shape[1]):  # iterate through other particles
            other_particle = hardcode_attributes(Context_Particle(other[s,o,:,:]).to_dict(), False)
            sample_particles.append(other_particle)
        samples.append(sample_particles)
    return samples

def recover_path(this, other):
    """
            this:     (num_samples, winsize/2, 8) -- TODO 1in1out
            other:    (num_samples, num_other_particles, winsize/2, 8) -- TODO 1in1out

        output
            a list of paths, each like
                (winsize, [pos, vel], numObjects, [x, y])
    """
    num_samples = this.shape[0]
    samples = []
    for s in xrange(this.shape[0]):
        # get it to (numObjects, winsize, [pos vel] [x y])
        sample_particles = []
        this_particle = Context_Particle(this[s,:,:])
        this_particle_reshaped_path = this_particle.reshape_path(this_particle.path)
        assert this_particle_reshaped_path.shape == (this.shape[1],2,2)
        sample_particles.append(this_particle_reshaped_path)

        for o in xrange(other.shape[1]):
            other_particle = Context_Particle(other[s,o,:,:])
            sample_particles.append(other_particle.reshape_path(other_particle.path))

        sample_particles = stack(sample_particles)  # (numObjects, winsize, [pos vel] [x y])

        # Now transpose to (winsize, [pos, vel], numObjects, [x, y])
        sample_particles = np.transpose(sample_particles, (1, 2, 0, 3))  # works
        samples.append(sample_particles)
    return samples

def recover_state(this, context, this_pred, config):
    """
        input
            this:       (num_samples, winsize/2, 8)
                past
            context:    (num_samples, G_num_objects, winsize/2, 8)
                may be future or past
            this_pred:       (num_samples, winsize/2, 8)
                must match the time of context
                    can be ground truth if you want to render ground truth
                    or prediction if you want to render prediction
            config:     something like: worldm1_np=1_ng=1

        output
            observedPath    = (winsize, [pos, vel], numObjects, [x, y])

            particles
                list of something like
                {'color': 'red',
                  'field-color': 'black',  # we hardcode this
                  'mass': 1.0,
                  'size': 40.0},  # we hardcode this

            goos
                something like
                [[[511, 289] [674, 422] 0 'darkmagenta']
                 [[217, 352] [327, 561] 0 'darkmagenta']
                 [[80, 155] [205, 299] 0 'darkmagenta']
                 [[530, 393] [617, 598] 0 'darkmagenta']
                 [[171, 36] [389, 149] 0 'darkmagenta']]
    """

    num_samples = len(this)

    # First separate out context
    # other: (num_samples, num_other_particles, winsize/2, 8)
    # goos: (num_samples, num_goos, winsize/2, 8)
    other, goos =  separate_context(context, config)

    # Next recover goos
    recovered_goos_all_samples = recover_goos(goos)

    # Next recover particles
    recovered_particles_all_samples = recover_particles(this, other)

    # Next recover path
    recoverd_path_all_samples = recover_path(this_pred, other)

    assert len(recovered_goos_all_samples) \
            == len(recovered_particles_all_samples) \
            == len(recoverd_path_all_samples) \
            == num_samples

    samples = []
    for sample_num in xrange(num_samples):
        # a tuple of (goos, particles, path) for that particular sample
        samples.append((recovered_goos_all_samples[sample_num],
                        recovered_particles_all_samples[sample_num],
                        recoverd_path_all_samples[sample_num]))
    return samples

def render_output(samples, sample_num, framerate, movie_folder, movieName, save, start_frame):
    """
        ground_truth_samples and predicted_samples: list of tuples
            tuple: (goo, particles, path)

            path    = (winsize, [pos, vel], numObjects, [x, y])

            particles
                list of something like
                {'color': 'red',
                  'field-color': 'black',  # we hardcode this
                  'mass': 1.0,
                  'size': 40.0},  # we hardcode this

            goos
                something like
                [[[511, 289] [674, 422] 0 'darkmagenta']
                 [[217, 352] [327, 561] 0 'darkmagenta']
                 [[80, 155] [205, 299] 0 'darkmagenta']
                 [[530, 393] [617, 598] 0 'darkmagenta']
                 [[171, 36] [389, 149] 0 'darkmagenta']]

            save: True if want to save pngs
    """
    sample = samples[sample_num]

    # render ground truth
    render(*sample[:],  # (goos, particles, obs_path)
            framerate=framerate,
            movie_folder=movie_folder,
            movieName=movieName,
            save=save,
            start_frame=start_frame)

def visualize_results(training_samples_hdf5, sample_num, vidsave, imgsave):
    """
        input
            training_samples_hdf5: something like 'worldm1_np=6_ng=5_[15,15].h5'

        Visualizes past as well as ground truth future and predicted future

        save: true if want to save vid
    """
    framerate = 10
    exp_root = os.path.dirname(os.path.dirname(training_samples_hdf5))
    movie_folder = os.path.join(exp_root, 'videos')
    if not os.path.exists(movie_folder): os.mkdir(movie_folder)
    config_name = os.path.basename(training_samples_hdf5)
    movieName = config_name[:config_name.rfind('_')]+'_ex='+str(sample_num)
    images_root = movie_folder + "/" + movieName

    d = load_dict_from_hdf5(training_samples_hdf5)
    config_name = training_samples_hdf5[:training_samples_hdf5.rfind('_')]

    samples_past = recover_state(d['this'], d['context'], d['this'], config_name)
    samples_future_gt = recover_state(d['this'], d['context_future'], d['y'], config_name)
    samples_future_pred = recover_state(d['this'], d['context_future'], d['pred'], config_name)

    windowsize = np.array(samples_past[2][2]).shape[0]

    print 'render past'
    render_output(samples_past, sample_num, framerate, movie_folder, movieName, vidsave, 0)
    print 'render future gt'
    render_output(samples_future_gt, sample_num, framerate, movie_folder, movieName, vidsave, windowsize)
    make_video(images_root, framerate, 'gndtruth', vidsave, imgsave)

    print 'render past'
    render_output(samples_past, sample_num, framerate, movie_folder, movieName, imgsave, 0)
    print 'render future pred'
    render_output(samples_future_pred, sample_num, framerate, movie_folder, movieName, save, windowsize)
    make_video(images_root, framerate, 'pred', vidsave, imgsave)

def make_video(images_root, framerate, mode, savevid, saveimgs):
    """
        mode: gndtruth | pred
    """
    if savevid:
        print 'Converting images in', images_root, 'to video'
        os.system('ffmpeg -r ' + str(framerate) +' -i '+ images_root + \
                    '-%4d.png -vb 20M -vf fps='+str(framerate)+ \
                    ' -pix_fmt yuv420p ' + images_root+'_' + mode +'.mp4')

    if not saveimgs:
        print 'Removing images from', images_root.replace('=', '\\=')
        for i in os.listdir(os.path.dirname(images_root)):
            if os.path.basename(images_root) in i and '.png' in i:
                os.system('rm ' + os.path.join(os.path.dirname(images_root), i))

if __name__ == "__main__":
    # save_all_datasets(True)

    # create_all_videos('/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/data/physics-data', 'movie_root_debug')
    # assert False

    # visualize_results('worldm1_np=6_ng=5_[15,15].h5', 0)
    # visualize_results('model_predictions/worldm1_np=6_ng=5_[3,3].h5', 0)


    # FOR THIS EXAMPLE:
    # h5_file = 'openmind/results_batch_size=100_seq_length=10_layers=2_rnn_dim=100_max_epochs=20floatnetwork/predictions/lr=0.0005_worldm3_np=3_ng=1_[101,200].h5'

    # visualize_results(h5_file, 2)  # fail
    # visualize_results(h5_file, 99)  # okay
    # visualize_results(h5_file, 98)  # bounce off wall: knows boundaries
    # visualize_results(h5_file, 96)  # moves in space, but noisily: it'd be nice to have crisp movement
    # visualize_results(h5_file, 93)  # moves in space, but there is a slight glitch
    # visualize_results(h5_file, 89)  # wobbles around: pure noise. Knows to stay close to where it's supposed to be
    # visualize_results(h5_file, 79)  # KNOWS HOW TO BOUNCE OFF WALLS! (predicted after bounce though)
    # visualize_results(h5_file, 65)  # KNOWS HOW TO BOUNCE OFF WALLS! (almost)
    # visualize_results(h5_file, 55)  # particle-particle fail
    # visualize_results(h5_file, 4)  # particle-particle fail

    # # FOR THIS EXAMPLE:
    # h5_file = 'openmind/results_batch_size=100_seq_length=10_layers=2_rnn_dim=100_max_epochs=20floatnetworkcurriculum/predictions/lr=0.0005_worldm3_np=2_ng=2_[101,200].h5'
    #
    # # visualize_results(h5_file, 2)  # fail
    # # visualize_results(h5_file, 99)  # okay
    # # visualize_results(h5_file, 98)  # bounce off wall: knows boundaries
    # visualize_results(h5_file, 96)  # moves in space, but noisily: it'd be nice to have crisp movement
    # # visualize_results(h5_file, 93)  # moves in space, but there is a slight glitch
    # visualize_results(h5_file, 89)  # wobbles around: pure noise. Knows to stay close to where it's supposed to be
    # visualize_results(h5_file, 79)  # KNOWS HOW TO BOUNCE OFF WALLS!

    # 1/20/16: in summary: it can handle going straight, but it cannot bounce off objects
    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs2/baselinesubsampled_opt_adam_lr_0.001/predictions/worldm1_np=5_ng=4_[1,50].h5'
    # visualize_results(h5_file, 1)  # can bounce off walls
    # visualize_results(h5_file, 2)  # does not learn to bounce off other objects
    # visualize_results(h5_file, 3)  # does not learn to bounce off other objects Need a crisper way to model collisions
    # visualize_results(h5_file, 4)  # can definitely bounce off walls. I think we just need more training examples of particle collisions
    # visualize_results(h5_file, 5)    # soft "bounce"
    # visualize_results(h5_file, 6)    # reproduces linear motion very nicely
    # visualize_results(h5_file, 7)    # bounces off imaginary wall, soft bounce. Note though that a lot of the ground truth also have soft bounces
    # visualize_results(h5_file, 8)    # instead of bouncing, it slows down
    # visualize_results(h5_file, 9)    # no obj-obj bouncing interaction
    # visualize_results(h5_file, 10)    # bounces off imaginary wall
    # visualize_results(h5_file, 11)     # bounces off imaginary wall. How do something that is crisp?
    # visualize_results(h5_file, 12)     # bounces off imaginary wall. How do something that is crisp?
    # visualize_results(h5_file, 15)     #  GREAT EXAMPLE OF BOUNCING OFF WALL
    # visualize_results(training_samples_hdf5=h5_file, sample_num=16, vidsave=False, imgsave=False)     #  did not bounce against other object; good example
    # visualize_results(h5_file, 18)     #  definitive example of NOT BOUNCING OFF OBJECTS
    # visualize_results(h5_file, 19)     # GREAT EXAMPLE OF BOUNCING OFF WALL
    # visualize_results(h5_file, 26)     # DOES NOT BOUNCE OFF OTHER OBJECTS
    # visualize_results(h5_file, 27)     # Bounces off corner
    # visualize_results(h5_file, 34)     # Example of a bad ground truth rendering

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs2/baselinesubsampled_opt_adam_lr_0.001/predictions/worldm1_np=1_ng=4_[1,50].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=16, vidsave=False, imgsave=False)     #  moved slower
    # visualize_results(training_samples_hdf5=h5_file, sample_num=7, vidsave=False, imgsave=False)     #  bounces well off wall
    # visualize_results(training_samples_hdf5=h5_file, sample_num=2, vidsave=True, imgsave=False)     #  straight line

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs2/baselinesubsampled_opt_adam_lr_0.001/predictions/worldm1_np=2_ng=0_[1,50].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=2, vidsave=False, imgsave=False)       # soft bounce off wall
    # visualize_results(training_samples_hdf5=h5_file, sample_num=3, vidsave=True, imgsave=False)        # moves straight
    # visualize_results(training_samples_hdf5=h5_file, sample_num=6, vidsave=False, imgsave=False)        # moves wrong direction
    # visualize_results(training_samples_hdf5=h5_file, sample_num=9, vidsave=True, imgsave=False)         # CANNOT BOUNCE               # SAVED
    # visualize_results(training_samples_hdf5=h5_file, sample_num=18, vidsave=False, imgsave=False)         # Great bounce
    # visualize_results(training_samples_hdf5=h5_file, sample_num=20, vidsave=False, imgsave=False)         # moves wrong direction

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs2/baselinesubsampled_opt_adam_lr_0.001/predictions/worldm1_np=3_ng=0_[1,50].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=1, vidsave=True, imgsave=False)       # CANNOT BOUNCE                 # SAVED
    # visualize_results(training_samples_hdf5=h5_file, sample_num=2, vidsave=False, imgsave=False)       # CANNOT BOUNCE                # SAVED
    # visualize_results(training_samples_hdf5=h5_file, sample_num=7, vidsave=False, imgsave=False)       # CANNOT BOUNCE

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs2/baselinesubsampled_opt_adam_lr_0.001/predictions/worldm4_np=5_ng=4_[1,50].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=1, vidsave=False, imgsave=False)       # Stays stationary if stationary
    # visualize_results(training_samples_hdf5=h5_file, sample_num=5, vidsave=False, imgsave=False)       # Friction seems to have an effect?
    # visualize_results(training_samples_hdf5=h5_file, sample_num=9, vidsave=False, imgsave=False)       # Cannot bounce off objects
    # visualize_results(training_samples_hdf5=h5_file, sample_num=11, vidsave=False, imgsave=False)       # An example that performs well
    # visualize_results(training_samples_hdf5=h5_file, sample_num=12, vidsave=False, imgsave=False)       # Cannot bounce off objects
    # visualize_results(training_samples_hdf5=h5_file, sample_num=13, vidsave=True, imgsave=False)       # CANNOT BOUNCE OFF OBJECTS    # SAVED


    # 1/25/16 only 2 balls
    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/baselinesubsampledcontig_opt_optimrmsprop_testcfgs_[:-2:2-:]_traincfgs_[:-2:2-:]_lr_0.001/predictions/worldm1_np=2_ng=0_[1,50].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=34, vidsave=False, imgsave=False)        # inertia good
    # visualize_results(training_samples_hdf5=h5_file, sample_num=7, vidsave=False, imgsave=False)        # CANNOT BOUNCE
    # visualize_results(training_samples_hdf5=h5_file, sample_num=10, vidsave=False, imgsave=False)        # Bad bounce off wall
    # visualize_results(training_samples_hdf5=h5_file, sample_num=13, vidsave=False, imgsave=False)        # Soft bounce off corner
    # visualize_results(training_samples_hdf5=h5_file, sample_num=29, vidsave=True, imgsave=False)        # Great bounce off wall
    # visualize_results(training_samples_hdf5=h5_file, sample_num=33, vidsave=False, imgsave=False)        # can bounce off objects (maybe?)
    # visualize_results(training_samples_hdf5=h5_file, sample_num=38, vidsave=False, imgsave=False)           # cannot bounce off objects (it seems to tweak physics such that it doesn't have to bounce off the other guy)

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/baselinesubsampledcontig_opt_optimrmsprop_testcfgs_[:-2:2-:]_traincfgs_[:-2:2-:]_lr_0.001/predictions/worldm1_np=2_ng=0_[51,100].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=2, vidsave=False, imgsave=False)        # bad bounce off wall
    # visualize_results(training_samples_hdf5=h5_file, sample_num=7, vidsave=True, imgsave=False)        # CANNOT BOUNCE          # Saved
    # visualize_results(training_samples_hdf5=h5_file, sample_num=22, vidsave=True, imgsave=False)       # Knows that there was an obj obj bounce in past    #SAVED
    # visualize_results(training_samples_hdf5=h5_file, sample_num=26, vidsave=True, imgsave=False)       # Remembers one wall, but not really the other    #SAVED
    # visualize_results(training_samples_hdf5=h5_file, sample_num=32, vidsave=False, imgsave=False)       # Switches direction somehow
    # visualize_results(training_samples_hdf5=h5_file, sample_num=38, vidsave=True, imgsave=False)       # DEFINITIVE CANNOT BOUNCE      # SAVED  # SHOW THIS
    # visualize_results(training_samples_hdf5=h5_file, sample_num=46, vidsave=True, imgsave=False)       # cannot bounce
    # visualize_results(training_samples_hdf5=h5_file, sample_num=49, vidsave=False, imgsave=False)       # knows that there is a corner

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/baselinesubsampledcontigdense_opt_adam_testcfgs_[:-2:2-:]_traincfgs_[:-2:2-:]_lr_0.001_batch_size_260/predictions/worldm1_np=2_ng=0_[1,260].h5'
    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/baselinesubsampledcontigdense2_opt_adam_traincfgs_[:-2:2-:]_shuffle_false_lrdecay_1_batch_size_260_testcfgs_[:-2:2-:]_lr_0.001/predictions/worldm1_np=2_ng=0_[1,260].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=5, vidsave=True, imgsave=False)        # CANNOT BOUNCE OFF OBJECTS
    # visualize_results(training_samples_hdf5=h5_file, sample_num=14, vidsave=True, imgsave=False)        # CANNOT BOUNCE OFF OBJECTS
    # visualize_results(training_samples_hdf5=h5_file, sample_num=26, vidsave=True, imgsave=False)        # Fast movement
    # visualize_results(training_samples_hdf5=h5_file, sample_num=30, vidsave=True, imgsave=False)        # CANNOT BOUNCE OFF OBJECTS
    # visualize_results(training_samples_hdf5=h5_file, sample_num=43, vidsave=True, imgsave=False)        # CANNOT BOUNCE OFF OBJECTS
    # visualize_results(training_samples_hdf5=h5_file, sample_num=53, vidsave=False, imgsave=False)        # CANNOT BOUNCE OFF OBJECTS


    # h5_file ='/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/baselinesubsampledcontigdense3_opt_adam_traincfgs_[:-2:2-:]_shuffle_true_lrdecay_0.99_batch_size_260_testcfgs_[:-2:2-:]_lr_0.005/predictions/worldm1_np=2_ng=0_[1,260].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=5, vidsave=False, imgsave=False)
    # for i in range(1, 20):
        # print(len(subsample_range(80, 2, i))), subsample_range(80, 20, i)
    # print(len(subsample_range(80, 2, 60))), subsample_range(80, 2, 60)
    # render_from_scheme_output('/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/data/physics-data/worldm1_np=1_ng=0/worldm1_np=1_ng=0_324.ss', 3, 'heyhey', 'hihi', False)

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/5_Sl1BCELinearReLU_opt_optimrmsprop_lr_0.001/predictions/worldm1_np=2_ng=0_[1,65].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=14, vidsave=False, imgsave=False)   # CANNOT BOUNCE OFF OBJECTS

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/2_TanhReLU_opt_optimrmsprop_layers_2_traincfgs_[:-2:2-:]_shuffle_true_lrdecay_0.99_batch_size_65_testcfgs_[:-2:2-:]_lr_0.001_max_epochs_20/predictions/worldm1_np=2_ng=0_[1,65].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=5, vidsave=False, imgsave=False)        # CANNOT BOUNCE OFF OBJECTS

    #
    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/4_SL1TanhReLU_opt_adam_lr_0.001/predictions/worldm1_np=2_ng=0_[1,65].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=5, vidsave=False, imgsave=False)        # CANNOT BOUNCE OFF OBJECTS

    # print subsample_range(80, 20, 60)

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/6_SL1BCELinearReLURel_opt_optimrmsprop_lr_0.001/predictions/worldm1_np=2_ng=0_[1,65].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=15, vidsave=False, imgsave=False)        # CANNOT BOUNCE OFF OBJECTS ON TRAINING DATA

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/9_opt_optimrmsprop_layers_2_lr_0.005/predictions/worldm1_np=2_ng=0_[1,80].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=9, vidsave=False, imgsave=False)

    h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/10_opt_optimrmsprop_layers_2_rnn_dim_256_lr_0.0005/predictions/worldm1_np=2_ng=0_[1,400].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=3, vidsave=False, imgsave=False)    # weird movement
    visualize_results(training_samples_hdf5=h5_file, sample_num=40, vidsave=False, imgsave=False)    # cannot bounce
    # visualize_results(training_samples_hdf5=h5_file, sample_num=130, vidsave=False, imgsave=False)    # cannot bounce

    # running simulation
    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/11_opt_optimrmsprop_layers_1_rnn_dim_256_lr_0.001/predictions/worldm1_np=2_ng=0_[1,80].h5'
    # visualize_results(training_samples_hdf5=h5_file, sample_num=20, vidsave=False, imgsave=False)  # possible bounce? look at 20, 21, 22
    # visualize_results(training_samples_hdf5=h5_file, sample_num=53, vidsave=False, imgsave=False)  # very soft bounce off wall

    # h5_file = '/Users/MichaelChang/Documents/Researchlink/SuperUROP/Code/dynamics/oplogs/11_opt_optimrmsprop_layers_1_rnn_dim_256_lr_0.001/predictions/worldm1_np=2_ng=0_[81,160].h5'
    # # visualize_results(training_samples_hdf5=h5_file, sample_num=40, vidsave=False, imgsave=False)  # inertia, simulation
    # visualize_results(training_samples_hdf5=h5_file, sample_num=50, vidsave=False, imgsave=False)
