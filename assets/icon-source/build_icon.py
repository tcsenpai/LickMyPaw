import math,subprocess,sys,os
# squircle (superellipse n=5) 824x824 centred in 1024
def squircle(n=4.6,r=412,c=512,N=360):
    pts=[]
    for i in range(N):
        t=2*math.pi*i/N; ct,st=math.cos(t),math.sin(t)
        pts.append((c+r*math.copysign(abs(ct)**(2/n),ct), c+r*math.copysign(abs(st)**(2/n),st)))
    return "M"+" L".join(f"{x:.2f},{y:.2f}" for x,y in pts)+"Z"
sq=squircle()
# paw geometry derived from lesnivila "Black Cat Paw" (CC0): 4 toe ellipses + pad (dome ellipse cut by trapezoid)
glyph='''<g id="paw">
<ellipse cx="218.6" cy="295.5" rx="87.1" ry="108.6"/><ellipse cx="377.1" cy="121.2" rx="87.1" ry="108.6"/>
<ellipse cx="625.7" cy="121.2" rx="87.1" ry="108.6"/><ellipse cx="820" cy="241.2" rx="87.1" ry="108.6"/>
<path d="M292,395 A252.9,222.9 0 0 1 780,395 L657,631 L415,631 Z" stroke="url(#pawg)" stroke-width="40" stroke-linejoin="round"/>
</g>'''
# glyph bbox x131..907 (776) y12..631 (619); centre (519,321.5); scale to ~500 wide
s=0.70
svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
<clipPath id="body"><path d="{sq}"/></clipPath>
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1d0642"/><stop offset=".5" stop-color="#3b0f8f"/><stop offset="1" stop-color="#4c12b8"/></linearGradient>
<radialGradient id="glow" cx="700" cy="620" r="420" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#8a3dff" stop-opacity=".75"/><stop offset="1" stop-color="#8a3dff" stop-opacity="0"/></radialGradient>
<linearGradient id="pawg" gradientUnits="userSpaceOnUse" x1="0" y1="12" x2="0" y2="631"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#ffd1ec"/></linearGradient>
<linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".18"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
<filter id="sh" x="-30%" y="-30%" width="160%" height="170%"><feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="16"/><feComponentTransfer><feFuncA type="linear" slope=".45"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>
<filter id="bsh" x="-10%" y="-10%" width="120%" height="125%"><feGaussianBlur in="SourceAlpha" stdDeviation="12"/><feOffset dy="10"/><feComponentTransfer><feFuncA type="linear" slope=".4"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>
<g filter="url(#bsh)"><path d="{sq}" fill="url(#bg)"/></g>
<g clip-path="url(#body)">
<rect width="1024" height="1024" fill="url(#glow)"/>
<rect x="100" y="100" width="824" height="400" fill="url(#gloss)"/>
</g>
<path d="{sq}" fill="none" stroke="#fff" stroke-opacity=".10" stroke-width="2"/>
<g filter="url(#sh)" fill="url(#pawg)" transform="translate(512 512) scale({s}) translate(-519 -321.5)">{glyph.replace('<g id="paw">','<g>')}</g>
</svg>'''
open('icon.svg','w').write(svg)
subprocess.run(['rsvg-convert','-w','1024','-h','1024','icon.svg','-o','AppIcon-1024.png'],check=True)
os.makedirs('AppIcon.iconset',exist_ok=True)
for b in (16,32,128,256,512):
    for m in (1,2):
        out=f'AppIcon.iconset/icon_{b}x{b}'+('@2x' if m==2 else '')+'.png'
        subprocess.run(['rsvg-convert','-w',str(b*m),'-h',str(b*m),'icon.svg','-o',out],check=True)
subprocess.run(['iconutil','-c','icns','AppIcon.iconset','-o','AppIcon.icns'],check=True)
