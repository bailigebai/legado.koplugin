"""Render production receipt layouts with desktop fonts; not a Kindle screenshot.

Uses the existing Lua/native-widget harness and Pillow only at the graphics boundary.
Run: .tools/python/python.exe scripts/preview_receipts.py
"""
from __future__ import annotations

import argparse
from functools import lru_cache
from pathlib import Path

from lupa.luajit21 import LuaRuntime
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent


@lru_cache(maxsize=128)
def font(size, bold=False):
    return ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc' if bold else 'C:/Windows/Fonts/msyh.ttc', max(1, round(size)))


def measure(value, size, bold=False):
    return font(size, bool(bold)).getlength(str(value))


def truncate(value, size, width, bold=False):
    value = str(value)
    if measure(value, size, bold) <= width:
        return value
    while value and measure(value + '…', size, bold) > width:
        value = value[:-1]
    return value + '…'


def render(style, width_percent, height_percent, controls=False, empty=False):
    image = Image.new('RGB', (600, 800), '#eeeeee')
    draw = ImageDraw.Draw(image)
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().root_path = ROOT.as_posix()
    lua.execute("package.path=root_path..'/legado.koplugin/?.lua;'..root_path..'/spec/?.lua;'..package.path")
    lua.execute("h=require('native_library_harness').install(root_path..'/.tools/koreader')")

    def rectangle(kind, x, y, w, h, color=0, border=1, radius=0):
        box = (round(x), round(y), round(x + w - 1), round(y + h - 1))
        color = (int(color),) * 3
        if kind == 'border':
            draw.rounded_rectangle(box, radius=radius or 0, outline=color, width=max(1, round(border)))
        else:
            draw.rounded_rectangle(box, radius=radius or 0, fill=color)

    def paint_text(node, x, y, multiline):
        size, bold = node.face.size, bool(node.bold)
        f = font(size, bold)
        w = node.width if multiline else (node.max_width or 600)
        h = node.height if multiline else size + 8
        value = str(node.text or '')
        lines = []
        if multiline:
            line = ''
            for ch in value:
                if ch == '\n' or measure(line + ch, size, bold) > w:
                    lines.append(line)
                    line = '' if ch == '\n' else ch
                else:
                    line += ch
            lines.append(line)
            limit = max(1, int(h / (size * 1.2)))
            if len(lines) > limit:
                lines = lines[:limit]
                lines[-1] = truncate(lines[-1] + '…', size, w, bold)
        else:
            lines = [truncate(value, size, w, bold)]
        for i, line in enumerate(lines):
            xx = x + max(0, (w - measure(line, size, bold)) / 2) if multiline and node.alignment == 'center' else x
            draw.text((round(xx), round(y + i * size * 1.2 + (0 if multiline else 2))), line, font=f,
                      fill=(int(node.fgcolor or 0),) * 3, anchor='lt')

    def cover(x, y, w, h):
        # Original geometric placeholder artwork; a 2:3 cover fitted without stretching.
        cw, ch = min(w, h * 2 / 3), min(h, w * 3 / 2)
        x, y = x + (w - cw) / 2, y + (h - ch) / 2
        draw.rectangle((x, y, x + cw, y + ch), fill='#dadad3', outline='#555555')
        draw.rectangle((x + cw * .08, y + ch * .06, x + cw * .92, y + ch * .94), outline='#666666')
        draw.ellipse((x + cw * .17, y + ch * .44, x + cw * .83, y + ch * .87), outline='#777777', width=1)
        draw.line((x + cw * .1, y + ch * .76, x + cw * .9, y + ch * .76), fill='#777777')
        draw.text((x + cw / 2, y + ch * .17), '山间来信', font=font(cw * .15, True), fill='black', anchor='mt')
        draw.text((x + cw / 2, y + ch * .35), '林  山', font=font(cw * .09), fill='black', anchor='mt')

    lua.globals().py_rect = rectangle
    lua.globals().py_text = paint_text
    lua.globals().py_cover = cover
    lua.globals().py_measure = measure
    lua.globals().py_truncate = truncate
    lua.execute("""
        local util=require('util')
        util.splitToChars=function(value)
            local chars={}
            for ch in tostring(value):gmatch('[%z\\1-\\127\\194-\\244][\\128-\\191]*') do chars[#chars+1]=ch end
            return chars
        end
        local rt=require('ui/rendertext')
        rt.sizeUtf8Text=function(_,_,_,face,value,_,bold) return {x=py_measure(value,face.size,bold or false)} end
        rt.truncateTextByWidth=function(_,value,face,width,_,bold) return py_truncate(value,face.size,width,bold or false) end
        for _,name in ipairs{'textwidget','textboxwidget'} do
            local cls=require('ui/widget/'..name)
            cls.paintTo=function(self,bb,x,y)
                if self.dimen then self.dimen.x,self.dimen.y=x,y end
                py_text(self,x,y,name=='textboxwidget')
            end
        end
        require('ui/widget/imagewidget').paintTo=function(self,bb,x,y) py_cover(x,y,self.width,self.height) end
        bb=setmetatable({
            paintRect=function(_,x,y,w,h,c) py_rect('fill',x,y,w,h,c or 0) end,
            paintRoundedRect=function(_,x,y,w,h,c,r) py_rect('fill',x,y,w,h,c or 0,1,r or 0) end,
            paintBorder=function(_,x,y,w,h,b,c,r) py_rect('border',x,y,w,h,c or 0,b or 1,r or 0) end,
        },{__index=function() return function() end end})
    """)
    options = lua.table_from(dict(style=style, width_percent=width_percent, height_percent=height_percent))
    options.reading_model = lua.table_from(dict(
        book=lua.table_from(dict(id='preview', name='山间来信', author='林山')),
        seconds=68160, today_seconds=2520, day_count=23, start_date='2026-08-23', date_text='2026-09-14',
        fraction=.425, progress_text='42.5%', position_text='85 / 200', position_label='阅读位置',
        chapter_title='第八十五章  山风替我翻了一页', chapter_page=3, chapter_pages=12, chapter_fraction=.25,
        status='reading', rating=4, receipt_id='0923', comment='山风替我翻页，我替时光留下书签。'))
    if empty:
        options.reading_model = lua.table_from(dict(book=lua.table_from(dict(name='这是一部名字很长很长需要自动换行的小说', author='一位名字也很长的作者'))))
    else:
        options.cover_loader = lua.eval("function(_,cb) cb('preview.jpg') end")
    lua.globals().preview_options = options
    lua.execute("receipt=require('legado.ui.receipt_screen').new(preview_options);receipt:paintTo(bb,0,0)")
    if controls:
        lua.execute("receipt:onGesture{ges='tap',pos={x=300,y=100}};receipt:paintTo(bb,0,0)")
    lua.execute("receipt:closeForReplacement()")
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/receipt-styles-20260914')
    parser.add_argument('--width', type=int, default=75)
    parser.add_argument('--height', type=int, default=90)
    parser.add_argument('--controls', action='store_true')
    parser.add_argument('--empty', action='store_true')
    parser.add_argument('--styles', nargs='+', help='render only these style IDs, in their menu order')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    lua = LuaRuntime()
    catalog = lua.execute((ROOT / 'legado.koplugin/legado/lib/receipt_styles.lua').read_text(encoding='utf-8')).list
    styles = [(catalog[i][1], catalog[i][2]) for i in range(1, len(catalog) + 1)]
    if args.styles:
        unknown = set(args.styles) - {entry[0] for entry in styles}
        if unknown:
            parser.error('unknown receipt style: ' + ', '.join(sorted(unknown)))
        styles = [entry for entry in styles if entry[0] in args.styles]
    rows = (len(styles) + 2) // 3
    sheet = Image.new('RGB', (1800, rows * 850), 'white')
    draw = ImageDraw.Draw(sheet)
    for i, (style_id, name) in enumerate(styles):
        rendered = render(style_id, args.width, args.height, args.controls, args.empty)
        rendered.save(args.output / (style_id + '.png'))
        x, y = i % 3 * 600, i // 3 * 850
        draw.text((x + 300, y + 10), name, font=font(22, True), fill='black', anchor='mt')
        sheet.paste(rendered, (x, y + 40))
    sheet.save(args.output / 'overview.png')
    sheet.crop((0, max(0, rows - 2) * 850, 1800, rows * 850)).save(args.output / 'six-new-styles.png')
    print(f'Production-layout preview (desktop fonts, not a device screenshot): {args.output}')


if __name__ == '__main__':
    main()
