from PIL import Image, ImageDraw, ImageFont
import os
B='/Users/bharatm/Downloads/MACdyna/brand'
W,H=2400,1720
sheet=Image.new('RGB',(W,H),(255,255,255)); d=ImageDraw.Draw(sheet)
def font(sz, wght=500):
    f=ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', sz)
    # Axes: Width, Optical Size, GRAD, Weight — normal width, optical size matched to the point size.
    f.set_variation_by_axes([100, max(17, min(96, sz)), 400, wght])
    return f
INK=(10,10,11); GREY=(99,100,103); LIGHT=(142,142,147); NIGHT=(10,10,11)
def place(path, box, bg=None):
    x,y,w,h=box
    if bg: d.rounded_rectangle((x,y,x+w,y+h), radius=28, fill=bg)
    im=Image.open(path).convert('RGBA'); s=min((w-80)/im.width,(h-80)/im.height)
    im=im.resize((int(im.width*s),int(im.height*s)),Image.LANCZOS)
    sheet.paste(im,(x+(w-im.width)//2,y+(h-im.height)//2),im)
def label(t,x,y,c=GREY,sz=22,w=500): d.text((x,y),t,fill=c,font=font(sz,w))
# Header
label('MAC FLOW — BRAND KIT',90,70,GREY,22,600)
label('Mark, wordmark, lockups, icon and colour',90,104,INK,40,600)
# Primary logo, light and dark
place(f'{B}/png/macflow-logo-stacked-light-3150px.png',(90,180,1080,560),(246,246,248))
place(f'{B}/png/macflow-logo-stacked-dark-3150px.png',(1230,180,1080,560),NIGHT)
label('Primary logo — stacked',90,752); label('On dark',1230,752)
# Horizontal, mark, star, icon
place(f'{B}/png/macflow-logo-horizontal-light-4132px.png',(90,810,720,250),(246,246,248))
place(f'{B}/png/macflow-mark-black-2128px.png',(840,810,450,250),(246,246,248))
place(f'{B}/png/macflow-star-black-1331px.png',(1320,810,300,250),(246,246,248))
place(f'{B}/icon/macflow-app-icon-light-1024px.png',(1650,800,300,270))
place(f'{B}/png/macflow-mark-white-2128px.png',(1980,810,330,250),NIGHT)
label('Horizontal lockup',90,1072); label('Mark',840,1072); label('Flow — the star',1320,1072); label('App icon',1650,1072); label('Mark on dark',1980,1072)
# Colours
y=1150
label('COLOUR',90,y,GREY,20,600)
sw=[('Ink',INK,'#0A0A0B',"“Mac”, the mark"),('Flow grey',GREY,'#636467','“Flow” on light'),('Paper',(255,255,255),'#FFFFFF','Backgrounds'),('Flow on dark',LIGHT,'#8E8E93','“Flow” on dark'),('Flow violet',(158,133,255),'#9E85FF','The assistant, in the app')]
for i,(n,c,hexs,use) in enumerate(sw):
    x=90+i*296
    d.rounded_rectangle((x,y+40,x+262,y+170),radius=22,fill=c,outline=(225,225,230),width=2)
    label(n,x,y+186,INK,24,600); label(hexs,x,y+218,GREY,19,500); label(use,x,y+244,GREY,18,450)
# Typography & rules
x0=1640
label('TYPE',x0,y,GREY,20,600)
d.text((x0,y+36),'Mac',fill=INK,font=font(64,520)); d.text((x0+d.textlength('Mac ',font=font(64,520)),y+36),'Flow',fill=GREY,font=font(64,520))
label('SF Pro, Medium — wordmark',x0,y+120,INK,22,600)
label('SF Pro — interface (system font)',x0,y+152,GREY,20,450)
label('RULES',x0,y+210,GREY,20,600)
rules=['Clear space: half the mark’s height on every side.','Minimum: mark 16 px tall on screen; wordmark 12 px.','Never recolour the star, stretch, rotate or outline the mark.','The star alone means Flow, the assistant.']
for i,r in enumerate(rules): label('· '+r,x0,y+244+i*30,INK,19,450)
sheet.save(f'{B}/macflow-brand-sheet.png'); print('sheet ok', sheet.size)
