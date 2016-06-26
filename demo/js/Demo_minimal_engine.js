/**
* The Matter.js demo page controller and example runner.
*
* NOTE: For the actual example code, refer to the source files in `/examples/`.
*
* @class Demo
*/

(function() {

    var _isBrowser = typeof window !== 'undefined' && window.location,
        _useInspector = _isBrowser && window.location.hash.indexOf('-inspect') !== -1,
        _isMobile = _isBrowser && /(ipad|iphone|ipod|android)/gi.test(navigator.userAgent),
        _isAutomatedTest = !_isBrowser || window._phantom;

    // var Matter = _isBrowser ? window.Matter : require('../../build/matter-dev.js');
    var Matter = _isBrowser ? window.Matter : require('matter-js');

    var Demo = {};
    Matter.Demo = Demo;

    if (!_isBrowser) {
        var jsonfile = require('jsonfile')
        var CircularJSON = require('circular-json')
        var assert = require('assert')
        var utils = require('../../utils')
        var sleep = require('sleep')
        require('./Examples')
        var env = process.argv.slice(2)[0]
        if (env == null)
            throw('Please provide an enviornment, e.g. node Demo.js hockey')
        module.exports = Demo;
        window = {};
    }

    // Matter aliases
    var Body = Matter.Body,
        Example = Matter.Example,
        Engine = Matter.Engine,
        World = Matter.World,
        Common = Matter.Common,
        Composite = Matter.Composite,
        Bodies = Matter.Bodies,
        Events = Matter.Events,
        Runner = Matter.Runner,
        Render = Matter.Render;

    // Create the engine
    Demo.run = function(json_data) {

        // here we extract the world from the loaded engine
        console.log(json_data.bodies)
        console.log(json_data.bodies[0].position)
        console.log(json_data.gravity)

        var demo = {}
        var load_engine = Engine.create({world: json_data})
        // demo.engine = Engine.create()
        demo.engine = Engine.create({world: json_data}) // if you are loading the world
        Engine.merge(demo.engine, load_engine)
        console.log(demo.engine.world)  // the bodies here do not reflect the bodies in json_data? why?
        console.log(demo.engine.world.gravity)  // the bodies here do not reflect the bodies in json_data?
        console.log(demo.engine.world.bodies[0].position)  // the bodies here do  reflect the bodies in json_data? // perhaps I need to manually set the position? but what else should I manually set?

        demo.runner = Engine.run(demo.engine)
        demo.container = document.getElementById('canvas-container');
        demo.render = Render.create({element: demo.container, engine: demo.engine})
        Render.run(demo.render)

        // console.log(demo.engine.world)
        // why isn't it running?
        // do I need to set a scene name? what does the scene name have the I don't?

        // hmmm, maybe I don't even need all of this

        // demo.w_offset = 5;  // world offset
        // demo.w_cx = 400;
        // demo.w_cy = 300;
        //
        // var world_border = Composite.create({label:'Border'});
        //
        // Composite.add(world_border, [
        //     Bodies.rectangle(demo.w_cx, -demo.w_offset, 2*demo.w_cx + 2*demo.w_offset, 2*demo.w_offset, { isStatic: true, restitution: 1 }),
        //     Bodies.rectangle(demo.w_cx, 600+demo.w_offset, 2*demo.w_cx + 2*demo.w_offset, 2*demo.w_offset, { isStatic: true, restitution: 1 }),
        //     Bodies.rectangle(2*demo.w_cx + demo.w_offset, demo.w_cy, 2*demo.w_offset, 2*demo.w_cy + 2*demo.w_offset, { isStatic: true, restitution: 1 }),
        //     Bodies.rectangle(-demo.w_offset, demo.w_cy, 2*demo.w_offset, 2*demo.w_cy + 2*demo.w_offset, { isStatic: true, restitution: 1 })
        // ]);
        //
        // World.add(demo.engine.world, world_border)  // its parent is a circular reference!
        //
        // var sceneName = 'm_balls'
        // Example[sceneName](demo);  // TODO I get an error here.

        // Ok, now let's manually update
        // Runner.stop(demo.runner)

        // console.log(json_data)

        //TODO: note that here you should load the demo engine with the json file


        // assert(false)

        // var trajectories = json_data[0]  // extra 0 for batch mode
        // var num_obj = trajectories.length
        // var num_steps = trajectories[0].length

        var i = 0
        function f() {
            console.log( i );

            ////////////////////////////////////////////////////////////////////
            // here you can manually set the postion.
            // Let's try it. Let's manually reset the position

            // HACKY, possibly can pass this into the Example[scenName](demo) as params
            // var num_obj = 2
            // var obj_radius = 60
            // rand_pos_fn = function() {
            //     return rand_pos(
            //         {hi: 2*demo.w_cx - obj_radius - 1, lo: obj_radius + 1},
            //         {hi: 2*demo.w_cy - obj_radius - 1, lo: obj_radius + 1});
            //     };
            // var p0 = initialize_positions(num_obj, obj_radius, rand_pos_fn)
            //
            var entities = Composite.allBodies(demo.engine.world)
                .filter(function(elem) {
                            return elem.label === 'Entity';
                        })
            var entity_ids = entities.map(function(elem) {
                                return elem.id});
            console.log(entities)
            //
            // for (id = 0; id < num_obj; id++) { //id = 0 corresponds to world!
            //     var body = Composite.get(demo.engine.world, entity_ids[id], 'body')
            //     // set the position here
            //     Body.setPosition(body, p0[id])
            // }


            // here instead we use set the ball's position based on the trajectory given by the file

            for (id = 0; id < entity_ids.length; id++) { //id = 0 corresponds to world!
                var body = Composite.get(demo.engine.world, entity_ids[id], 'body')
                // set the position here
                Body.setPosition(body, trajectories[id][i].position)
            }

            ////////////////////////////////////////////////////////////////////


            Runner.tick(demo.runner, demo.engine);
            i++;
            if( i < num_steps ){  // here you could replace true with a stopping condition
                setTimeout( f, 100 );
            }
        }
        // f();

    }

    // call init when the page has loaded fully
    if (!_isAutomatedTest) {
        window.loadFile = function loadFile(file){
            var fr = new FileReader();
            fr.onload = function(){
                Demo.run(window.CircularJSON.parse(fr.result))
            }
            fr.readAsText(file)
        }
    }
})();
