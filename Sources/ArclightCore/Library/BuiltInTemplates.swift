import Foundation

/// Built-in templates (data, not code). They use theme tokens ($fg, $bg, $muted, $accent, $display, $body)
/// and canvas placeholders ({{W}}, {{H}}, {{CX}}, {{CY}}) so they work in any style and aspect ratio.
enum BuiltInTemplates {
    static let all: [Template] = sources.compactMap { try? JSONDecoder().decode(Template.self, from: Data($0.utf8)) }

    static let sources: [String] = [title, counter, quote, lowerThird, statCrowd, spotlightCascade]

    static let title = #"""
        {"id":"title","name":"Title card","category":"Text","description":"Centred title with a line that draws on and a subtitle.",
         "params":[{"name":"title","kind":"text","default":"Chapter one"},{"name":"subtitle","kind":"text","default":"Where it all began"}],
         "scene":{"duration":4,"background":"$bg","nodes":[
           {"id":"title","type":"text","text":"{{title}}","font":"$display","size":120,"color":"$fg","align":"center",
            "x":"{{CX}}","y":{"expr":"{{CY}} - 110"},
            "reveal":{"by":"word","stagger":0.08,"duration":0.8,"ease":"outExpo","from":{"opacity":0,"y":70},"mask":true}},
           {"id":"rule","type":"shape","shape":"line","x":{"expr":"{{CX}} - 160"},"y":{"expr":"{{CY}} + 40"},"to":[320,0],
            "strokeWidth":3,"stroke":"$muted","trim":{"k":[[0.5,[0.5,0.5]],[1.3,[0,1],"inOutCubic"]]}},
           {"id":"subtitle","type":"text","text":"{{subtitle}}","font":"$body","size":40,"color":"$muted","align":"center",
            "x":"{{CX}}","y":{"expr":"{{CY}} + 80"},
            "reveal":{"by":"word","stagger":0.05,"delay":0.9,"duration":0.7,"from":{"opacity":0,"y":24}}}
         ]}}
        """#

    static let counter = #"""
        {"id":"counter","name":"Big counter","category":"Numbers","description":"A large number that counts up, with a label.",
         "params":[{"name":"value","kind":"number","default":72},{"name":"suffix","kind":"text","default":"%"},
                   {"name":"label","kind":"text","default":"of viewers never reach the end"}],
         "scene":{"duration":4,"background":"$bg","nodes":[
           {"id":"number","type":"text","text":"{v}{{suffix}}","font":"$display","size":320,"color":"$fg","align":"center","tabular":true,
            "x":"{{CX}}","y":{"expr":"{{CY}} - 230"},"value":{"k":[[0,0],[1.6,"{{value}}","outExpo"]]},
            "opacity":{"k":[[0,0],[0.3,1,"outCubic"]]}},
           {"id":"label","type":"text","text":"{{label}}","font":"$body","size":48,"color":"$muted","align":"center","uppercase":true,"tracking":2,
            "x":"{{CX}}","y":{"expr":"{{CY}} + 130"},
            "reveal":{"by":"word","stagger":0.06,"delay":0.8,"duration":0.7,"from":{"opacity":0,"y":30},"mask":true}}
         ]}}
        """#

    static let quote = #"""
        {"id":"quote","name":"Quote","category":"Text","description":"A quotation revealed word by word, with attribution.",
         "params":[{"name":"quote","kind":"text","default":"Simplicity is the\nultimate sophistication."},{"name":"author","kind":"text","default":"Leonardo da Vinci"}],
         "scene":{"duration":6,"background":"$bg","nodes":[
           {"id":"mark","type":"text","text":"“","font":"$display","size":260,"color":"$muted","x":120,"y":120,
            "opacity":{"k":[[0,0],[0.6,1,"outCubic"]]}},
           {"id":"quote","type":"text","text":"{{quote}}","font":"$display","size":84,"lineHeight":1.15,"color":"$fg","x":140,"y":330,
            "reveal":{"by":"word","stagger":0.06,"delay":0.3,"duration":0.7,"ease":"outExpo","from":{"opacity":0,"y":30}}},
           {"id":"author","type":"text","text":"— {{author}}","font":"$body","size":38,"color":"$muted","x":144,"y":{"expr":"{{H}} - 260"},
            "opacity":{"k":[[1.8,0],[2.4,1,"outCubic"]]}}
         ]}}
        """#

    static let lowerThird = #"""
        {"id":"lower-third","name":"Lower third","category":"Text","description":"Name and role that slide in and out at the bottom left. Export as ProRes to overlay on footage.",
         "params":[{"name":"name","kind":"text","default":"Alex Morgan"},{"name":"role","kind":"text","default":"Product designer"}],
         "scene":{"duration":5,"background":"#00000000","nodes":[
           {"id":"lt","type":"group","x":120,"y":{"expr":"{{H}} - 250"},
            "opacity":{"k":[[0,0],[0.4,1,"outCubic"],[4.4,1],[4.9,0,"inCubic"]]}},
           {"id":"bar","type":"shape","parent":"lt","shape":"rect","x":4,"y":60,"width":8,"height":120,"fill":"$fg",
            "scale":{"k":[[0,[1,0]],[0.5,[1,1],"outExpo"]]}},
           {"id":"name","type":"text","parent":"lt","text":"{{name}}","font":"$display","size":56,"color":"$fg","x":32,"y":0,
            "reveal":{"by":"char","stagger":0.02,"delay":0.2,"duration":0.6,"from":{"opacity":0,"x":-30}}},
           {"id":"role","type":"text","parent":"lt","text":"{{role}}","font":"$body","size":32,"color":"$muted","x":34,"y":78,
            "reveal":{"by":"word","stagger":0.05,"delay":0.45,"duration":0.6,"from":{"opacity":0,"x":-20}}}
         ]}}
        """#

    static let statCrowd = #"""
        {"id":"stat-crowd","name":"Stat with a crowd","category":"Numbers","description":"A 3D crowd where exactly value% light up, with a counter that follows the lights.",
         "params":[{"name":"value","kind":"number","default":45,"doc":"Percent of the crowd that lights up (0–100)."},
                   {"name":"caption","kind":"text","default":"of people felt the same way"},
                   {"name":"symbol","kind":"symbol","default":"basic/person"}],
         "scene":{"duration":6,"background":"$bg",
          "camera":{"expr":"var k = smoothstep(0, d, T); return {position:[{{CX}} - 200 + 60*k, -60 + 40*k, -400 + 140*k], target:[{{CX}} + 100, {{H}}*0.77, 1500], fov:36};"},
          "fog":{"color":"$bg","near":1500,"far":3400},
          "post":{"bloom":{"intensity":0.4,"threshold":1},"vignette":{"amount":0.6,"softness":0.8},"grain":0.03,"fade":{"in":0.3,"out":0.4}},
          "nodes":[
           {"id":"ambient","type":"light","x":"{{CX}}","y":{"expr":"{{H}}*0.77"},"z":1450,"pool":{"radius":1500,"intensity":0.12,"softness":1,"falloff":2,"color":"$fg"}},
           {"id":"crowd","type":"repeater","x":"{{CX}}","y":{"expr":"{{H}}*0.77"},"z":1500,"rotationY":15,
            "layout":"grid","cols":30,"rows":24,"spacing":100,"jitter":0.25,"seed":3,"color":"$muted",
            "items":[{"symbol":"{{symbol}}","height":100}],
            "instance":{"lit":{"expr":"var r = pick(i, n, {{value}}/100, 7); if (r < 0) return 0; return lamp(t, 0.4 + 2.0 * Math.sqrt((r + 1) / Math.round(n * {{value}}/100)));"},
                        "color":{"expr":"pick(i, n, {{value}}/100, 7) >= 0 && t > 0.4 ? '$fg' : '$muted'"}},
            "pool":{"radius":40,"color":"$fg","intensity":0.9,"softness":0.4},"rim":0.6},
           {"id":"counter","type":"text","text":"{v}%","font":"$display","size":260,"color":"$fg","x":100,"y":110,"tabular":true,
            "value":{"expr":"Math.min({{value}}, Math.ceil({{value}} * litCount('crowd') / Math.max(1, Math.round(instanceCount('crowd') * {{value}}/100))))"}},
           {"id":"caption","type":"text","text":"{{caption}}","font":"$display","size":56,"color":"$fg","uppercase":true,"tracking":1,"x":104,"y":420,
            "reveal":{"by":"word","stagger":0.07,"delay":0.6,"duration":0.8,"from":{"opacity":0,"y":60},"mask":true}}
         ]}}
        """#

    static let spotlightCascade = #"""
        {"id":"spotlight-cascade","name":"Spotlight cascade (chess)","category":"Numbers","description":"Black chess pieces on a checkerboard; exactly value% are lit by spotlights in an accelerating cascade. Black-and-white film look.",
         "params":[{"name":"value","kind":"number","default":45},{"name":"caption","kind":"text","default":"of people spent yesterday"},
                   {"name":"line2","kind":"text","default":"feeling lonely."}],
         "theme":{"ink":"#070707","pool":"#E2DDD2"},
         "scene":{"duration":8,"background":"$bg",
          "camera":{"expr":"var k = smoothstep(0, d, T); return {position:[{{CX}} - 200 + 70*k, -60 + 50*k, -380 + 140*k], target:[{{CX}} + 100, 830, 1500], fov:36, dof:{focus:1700 - 120*k, blur:9, range:0.45}, shake:[{at:2.85, y:8, roll:0.35}]};"},
          "fog":{"color":"#000000","near":1500,"far":3300},
          "post":{"bloom":{"intensity":0.45,"threshold":1},"vignette":{"amount":0.75,"softness":0.8},"grain":0.05,"saturation":0,
                  "motionBlur":{"samples":3,"shutter":0.5},"fade":{"in":0.4,"out":0.5}},
          "nodes":[
           {"id":"ambient","type":"light","x":1060,"y":830,"z":1450,"pool":{"radius":1500,"intensity":0.16,"softness":1,"falloff":2}},
           {"id":"crowd","type":"repeater","x":1000,"y":830,"z":1500,"rotationY":18,
            "layout":"grid","cols":40,"rows":36,"spacing":80,"jitter":0.25,"seed":4,"color":"$ink",
            "items":[{"symbol":"chess/pawn","height":90,"widthScale":0.8,"weight":58},{"symbol":"chess/bishop","height":100,"widthScale":0.8,"weight":13},
                     {"symbol":"chess/knight","height":100,"widthScale":0.8,"weight":13},{"symbol":"chess/queen","height":100,"widthScale":0.8,"weight":9},
                     {"symbol":"chess/king","height":100,"widthScale":0.8,"weight":7}],
            "instance":{"lit":{"expr":"var r = pick(i, n, {{value}}/100, 7); if (r < 0) return 0; var L = t - 2.85; return lamp(t, 0.4 + 2.4 * Math.sqrt((r + 1) / Math.round(n * {{value}}/100))) * (L > 0 ? 1 + 0.35 * Math.exp(-L * 4) : 1);"},
                        "scale":{"expr":"0.92 + rand(i * 5.3) * 0.16"}},
            "ground":{"color":"#101010","checker":{"opacity":0.04}},
            "pool":{"radius":32,"color":"$pool","intensity":1.3,"softness":0.3,"spill":{"radius":3,"intensity":0.12}},
            "contact":{"opacity":0.85},"shadow":{"opacity":0.8,"length":0.45,"angle":20},"cone":{"intensity":0.5}},
           {"id":"shade","type":"shape","x":960,"y":540,"width":1920,"height":1080,
            "fill":{"linear":[-960,-540,480,324],"stops":[[0,"#000000D9"],[0.55,"#00000066"],[1,"#00000000"]]}},
           {"id":"counter","type":"text","text":"{v}%","font":"$display","size":270,"color":"$fg","x":104,"y":100,"tabular":true,
            "value":{"expr":"Math.min({{value}}, Math.ceil({{value}} * litCount('crowd') / Math.max(1, Math.round(instanceCount('crowd') * {{value}}/100))))"}},
           {"id":"caption","type":"text","in":3.6,"text":"{{caption}}","font":"$display","size":60,"color":"$fg","uppercase":true,"x":106,"y":395,
            "reveal":{"by":"char","stagger":0.022,"duration":0.6,"ease":"outExpo","from":{"opacity":0,"y":30,"skew":12}}},
           {"id":"line2","type":"text","in":5.0,"text":"{{line2}}","font":"$display","size":60,"color":"$fg","uppercase":true,"x":106,"y":472,
            "reveal":{"by":"char","stagger":0.022,"duration":0.6,"ease":"outExpo","from":{"opacity":0,"y":30,"skew":12}}}
         ]}}
        """#
}
