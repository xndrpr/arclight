import Foundation

/// Built-in thumbnail layouts (`kind: preview`, 1280×720). They follow the feed rules: one focal point, 3–5 heavy
/// words, strong contrast, nothing important in the bottom-right timestamp corner. Theme tokens keep them on
/// brand; `image` parameters start as a placeholder silhouette until a photo is chosen.
enum PreviewTemplates {
    static let sources: [String] = [faceWords, beforeAfter, numberList, reaction, product, minimal]

    static let faceWords = #"""
        {"id":"thumb-face-words","kind":"preview","name":"Face + big words","category":"Thumbnails",
         "description":"Cut-out person on the right with a white outline, two heavy lines of text on the left, an accent glow behind.",
         "params":[{"name":"line1","label":"Line 1","kind":"text","default":"I QUIT"},
                   {"name":"line2","label":"Line 2 (accent)","kind":"text","default":"MY JOB"},
                   {"name":"photo","label":"Photo (cut out)","kind":"image","default":""}],
         "scene":{"size":[1280,720],"background":"$bg","nodes":[
           {"id":"glow","type":"shape","shape":"ellipse","x":930,"y":380,"width":760,"height":760,"fill":"$accent@35","effects":{"blur":80}},
           {"id":"photo","type":"image","src":"{{photo}}","x":930,"y":420,"height":640,
            "effects":{"outline":{"color":"#FFFFFF","width":14},"dropShadow":{"x":0,"y":18,"blur":36,"opacity":0.6}}},
           {"id":"line1","type":"text","text":"{{line1}}","font":"$display","size":200,"color":"$fg","x":64,"y":150,
            "effects":{"dropShadow":{"x":0,"y":10,"blur":24,"opacity":0.7}}},
           {"id":"line2","type":"text","text":"{{line2}}","font":"$display","size":200,"color":"$accent","x":64,"y":370,
            "effects":{"outline":{"color":"#000000","width":8},"dropShadow":{"x":0,"y":10,"blur":24,"opacity":0.7}}}
         ]}}
        """#

    static let beforeAfter = #"""
        {"id":"thumb-before-after","kind":"preview","name":"Before / after","category":"Thumbnails",
         "description":"Two pictures split down the middle with labels and an arrow.",
         "params":[{"name":"before","label":"Before photo","kind":"image","default":""},
                   {"name":"after","label":"After photo","kind":"image","default":""},
                   {"name":"left","label":"Left label","kind":"text","default":"BEFORE"},
                   {"name":"right","label":"Right label","kind":"text","default":"AFTER"}],
         "scene":{"size":[1280,720],"background":"$bg","nodes":[
           {"id":"before","type":"image","src":"{{before}}","x":320,"y":360,"width":640,"height":720,"fit":"cover","adjust":{"saturation":0.35,"brightness":-0.05}},
           {"id":"after","type":"image","src":"{{after}}","x":960,"y":360,"width":640,"height":720,"fit":"cover","adjust":{"saturation":1.25,"contrast":1.1}},
           {"id":"divider","type":"shape","shape":"rect","x":640,"y":360,"width":12,"height":720,"fill":"$fg"},
           {"id":"leftLabel","type":"text","text":"{{left}}","font":"$display","size":96,"color":"$fg","x":60,"y":56,
            "effects":{"outline":{"color":"#000000","width":8}}},
           {"id":"rightLabel","type":"text","text":"{{right}}","font":"$display","size":96,"color":"$accent","x":700,"y":56,
            "effects":{"outline":{"color":"#000000","width":8}}},
           {"id":"arrow","type":"shape","shape":"ellipse","x":640,"y":380,"width":150,"height":150,"fill":"$accent",
            "effects":{"outline":{"color":"#000000","width":8},"dropShadow":{"y":12,"blur":30,"opacity":0.6}}},
           {"id":"arrowGlyph","type":"text","text":"→","font":"$display","size":110,"color":"$bg","align":"center","x":640,"y":318}
         ]}}
        """#

    static let numberList = #"""
        {"id":"thumb-number","kind":"preview","name":"Big number","category":"Thumbnails",
         "description":"A huge number with a short promise — for lists and tips videos.",
         "params":[{"name":"number","label":"Number","kind":"text","default":"7"},
                   {"name":"line1","label":"Line 1","kind":"text","default":"HABITS"},
                   {"name":"line2","label":"Line 2","kind":"text","default":"THAT WORK"},
                   {"name":"photo","label":"Photo (optional)","kind":"image","default":""}],
         "scene":{"size":[1280,720],"background":"$bg","nodes":[
           {"id":"bgnum","type":"text","text":"{{number}}","font":"$display","size":660,"color":"$accent","x":30,"y":20,
            "effects":{"dropShadow":{"x":0,"y":20,"blur":50,"opacity":0.7}}},
           {"id":"photo","type":"image","src":"{{photo}}","x":1010,"y":440,"height":580,"effects":{"outline":{"color":"#FFFFFF","width":12}}},
           {"id":"line1","type":"text","text":"{{line1}}","font":"$display","size":150,"color":"$fg","x":420,"y":180,
            "effects":{"outline":{"color":"#000000","width":8}}},
           {"id":"line2","type":"text","text":"{{line2}}","font":"$display","size":110,"color":"$fg","x":420,"y":350,
            "effects":{"outline":{"color":"#000000","width":7}}}
         ]}}
        """#

    static let reaction = #"""
        {"id":"thumb-reaction","kind":"preview","name":"Reaction + object","category":"Thumbnails",
         "description":"Surprised face on the left, the thing on the right with a red circle, one word up top.",
         "params":[{"name":"photo","label":"Face","kind":"image","default":""},
                   {"name":"object","label":"Object photo","kind":"image","default":""},
                   {"name":"word","label":"Word","kind":"text","default":"WAIT…"}],
         "scene":{"size":[1280,720],"background":"$bg","nodes":[
           {"id":"photo","type":"image","src":"{{photo}}","x":330,"y":440,"height":620,
            "effects":{"outline":{"color":"#FFFFFF","width":12},"dropShadow":{"y":16,"blur":30,"opacity":0.6}}},
           {"id":"object","type":"image","src":"{{object}}","x":900,"y":420,"width":440,"height":440,"fit":"contain",
            "effects":{"dropShadow":{"y":20,"blur":40,"opacity":0.6}}},
           {"id":"circle","type":"shape","shape":"ellipse","x":900,"y":420,"width":500,"height":500,"fill":"#00000000",
            "stroke":"#FF2D2D","strokeWidth":16},
           {"id":"word","type":"text","text":"{{word}}","font":"$display","size":150,"color":"$accent","align":"center","x":640,"y":30,
            "effects":{"outline":{"color":"#000000","width":10}}}
         ]}}
        """#

    static let product = #"""
        {"id":"thumb-product","kind":"preview","name":"Big product","category":"Thumbnails",
         "description":"The product huge in the centre on a coloured glow, a short verdict beside it.",
         "params":[{"name":"photo","label":"Product photo","kind":"image","default":""},
                   {"name":"verdict","label":"Verdict","kind":"text","default":"WORTH IT?"}],
         "scene":{"size":[1280,720],"background":"$bg","nodes":[
           {"id":"glow","type":"shape","shape":"ellipse","x":560,"y":380,"width":820,"height":620,"fill":"$accent@45","effects":{"blur":90}},
           {"id":"photo","type":"image","src":"{{photo}}","x":560,"y":380,"height":600,
            "effects":{"dropShadow":{"x":0,"y":30,"blur":60,"opacity":0.7}}},
           {"id":"verdict","type":"text","text":"{{verdict}}","font":"$display","size":130,"color":"$fg","align":"right","x":1230,"y":60,
            "rotation":-4,"effects":{"outline":{"color":"#000000","width":9}}}
         ]}}
        """#

    static let minimal = #"""
        {"id":"thumb-minimal","kind":"preview","name":"Minimal title","category":"Thumbnails",
         "description":"Clean type on a flat colour with an accent bar — essays, podcasts, talks.",
         "params":[{"name":"title","label":"Title","kind":"text","default":"The quiet\nrevolution"},
                   {"name":"kicker","label":"Kicker","kind":"text","default":"EPISODE 12"}],
         "scene":{"size":[1280,720],"background":"$bg","nodes":[
           {"id":"bar","type":"shape","shape":"rect","x":120,"y":150,"width":120,"height":16,"fill":"$accent"},
           {"id":"kicker","type":"text","text":"{{kicker}}","font":"$body","size":40,"tracking":4,"color":"$muted","x":60,"y":190},
           {"id":"title","type":"text","text":"{{title}}","font":"$display","size":150,"lineHeight":0.95,"color":"$fg","x":56,"y":260}
         ]}}
        """#
}
