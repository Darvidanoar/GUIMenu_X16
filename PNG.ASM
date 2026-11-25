;******************************************************************
; PNG.ASM - the preview panel: find a PNG picture in the open
; folder, decode it and show it, shrunk (or enlarged) to fit.
;
; WHICH PICTURE
; If the highlighted file is a .PNG, that one is shown. Otherwise
; the first .PNG in the folder's file list is shown, so a folder
; holding GAME.PRG and GAME.PNG gets its picture as soon as it is
; opened. Decoding a PNG takes a while on an 8 MHz 6502 (seconds
; for a big one), so it starts PREVIEW_DELAY frames after the
; selection stops changing, and it stops as soon as a key is
; pressed or the mouse is clicked (the main loop then deals with
; the key or click, and the preview starts again afterwards).
;
; HOW THE PICTURE IS SHOWN
; The text screen is VERA layer 1. This file switches on layer 0,
; underneath it, as a "tile" layer with 8x8 pixel tiles of 256
; colours (1 byte per pixel). Its map lines up exactly with the
; text cells. Every cell of the preview panel gets its own tile
; (tiles 1-672, PREV_W x LIST_ROWS of them), so together the
; panel's tiles act like a 128x336 pixel bitmap. Everywhere else
; the map uses tile 0, which is all colour 0 = see-through.
; The panel's text cells are colour $00 (see-through background
; and foreground), so the tiles show through them.
;
;   pixel (x,y) of the panel is in tile 1 + (y/8)*16 + x/8,
;   at byte (y mod 8)*8 + (x mod 8) of that tile's 64 bytes.
;
; COLOURS
; VERA can show 256 colours, each chosen from 4096 (4 bits each of
; red, green and blue). Colours 0-15 are the text colours, 16 is
; the mouse pointer's outline and 128-255 are the logo, which
; leaves 17-127 (111 colours) for the picture. Each pixel's colour
; is cut down to 4 bits per channel; the first time a colour is
; seen it gets the next free palette entry, and once they are all
; used, new colours get the closest one already given out. A
; 4096-byte table in banked RAM remembers which entry each colour
; got. Screenshots of X16 programs (which only ever use colours
; VERA can show) come out exact.
;
; HOW A PNG FILE IS BUILT
;   8 bytes   signature: $89 "PNG" $0D $0A $1A $0A
;   chunks:   4 bytes length (big-endian: high byte first)
;             4 bytes type, e.g. "IHDR"
;             the data
;             4 bytes CRC (a checksum; we don't check it)
;
;   IHDR  width, height, bit depth, colour type, compression,
;         filter method, interlace
;   PLTE  the palette (for colour type 3)
;   tRNS  transparency (we use it for colour type 3)
;   IDAT  the pixels, compressed with "deflate" (the same method
;         as ZIP files). There can be several IDAT chunks: the
;         compressed data simply carries on from one to the next.
;   IEND  the end
;
; Colour types: 0 = grey, 2 = RGB, 3 = palette, 4 = grey + alpha,
; 6 = RGB + alpha. Bit depth = bits per value (1, 2, 4, 8 or 16).
;
; Once decompressed, the pixels are stored row by row, and each
; row starts with a "filter" byte that says how the row was coded:
;   0 None   the bytes as they are
;   1 Sub    each byte minus the byte one pixel to the left
;   2 Up     each byte minus the byte above it
;   3 Average  minus the average of left and above
;   4 Paeth  minus whichever of left, above and above-left is
;            closest to (left + above - above-left)
; Undoing the filter needs the previous row, so we keep two rows.
;
; DEFLATE
; The compressed data is a series of blocks. Each block is either
; stored (not compressed) or made of Huffman codes. A Huffman code
; is a string of bits; frequent things get short codes. A code
; means either a literal byte, or "copy N bytes from D bytes back"
; (a "match"), or end of block. So the decoder must keep the last
; 32 KB it produced (the "window"), which we keep in banked RAM.
; The Huffman codes are read one bit at a time, in the way of
; "puff" by Mark Adler (the simplest correct inflater).
;
; The decompressed bytes go into the window, and every 256 bytes
; or so "flush" undoes the row filters on them, copying them into
; the row buffer. When a row is complete, row_done picks out the
; pixels that are needed for the shrunk picture and writes them
; into the tiles.
;
; Timing on the 8 MHz X16: a 640x480 RGB screenshot takes about
; 10 seconds (most of it copying and unfiltering its 900 KB of
; pixel data), 320x240 about 2-3 seconds.
;
; Not supported (a message says so): interlaced PNGs, and rows of
; more than 8192 bytes (e.g. wider than 2730 pixels in RGB).
;******************************************************************

MACPTR            := $FF44        ; read many bytes from a file
                                  ;   (x16.inc calls $FF44 MONITOR)
KBDBUF_PEEK       := $FEBD        ; X = number of keys waiting

; ---- the panel ----
PV_W              = PREV_W*8      ; 128 pixels wide
PV_H              = LIST_ROWS*8   ; 336 pixels high
PV_TILES          = PREV_W*LIST_ROWS ; 672 tiles
PV_MSG_ROW        = LIST_TOP+LIST_ROWS-1 ; messages: bottom row
PV_BG             = $0F           ; background: palette entry F (grey)
PV_FIRST_COL      = 17            ; palette entries for the picture
PV_END_COL        = 128           ;   (17-127)
PREVIEW_DELAY     = 20            ; frames to wait before decoding

COL_PV_CLEAR      = $00           ; panel text cells: see-through
COL_PV_TEXT       = $0C           ; message: black, see-through behind

; ---- VRAM (see also LOGO_VRAM, the mouse pointer at $13000, the
;      text screen at $1B000 and the character set at $1F000) ----
TILE_VRAM         = $00000        ; tile 0, then the panel's tiles
                                  ;   (673*64 bytes, up to $0A840)
MAP_VRAM          = $14000        ; layer 0 map, 128x64 cells x 2
                                  ;   bytes = 16 KB, up to $17FFF

.assert PV_TILES < 1024, error, "too many preview tiles"
.assert TILE_VRAM + (PV_TILES+1)*64 <= LOGO_VRAM, error, "preview tiles overlap the logo"

; ---- banked RAM ----
WIN_BANK          = 6             ; banks 6-9: the 32 KB window
MAP_BANK          = 10            ; bank 10: colour table ($A000-$AFFF),
                                  ;   picture palette ($B000-$B3FF)
                                  ;   and colours given out ($B400-)
CMAP              = $A000         ; 4096 bytes: 12-bit colour -> entry
PLTE_R            = $B000         ; the PNG's palette, 256 x R, G, B,
PLTE_G            = $B100         ;   and alpha (from tRNS)
PLTE_B            = $B200
PLTE_A            = $B300
USED_R            = $B400         ; red/green/blue (0-15) of each
USED_G            = $B480         ;   palette entry given out, by
USED_B            = $B500         ;   entry number (0-127)

ROW_MAX           = 8192          ; longest row we can decode, bytes
LFN_PNG           = 3             ; logical file number for the PNG

; results of png_decode
PNG_OK            = 0
PNG_ABORT         = 1             ; a key or click interrupted it
PNG_ERR_OPEN      = 2             ; the rest are shown as messages
PNG_ERR_NOTPNG    = 3
PNG_ERR_TYPE      = 4
PNG_ERR_INTERLACE = 5
PNG_ERR_SIZE      = 6
PNG_ERR_DATA      = 7

.pushseg
.segment "ZEROPAGE"
in_ptr:   .res 2                  ; next byte in inbuf
win_ptr:  .res 2                  ; next free byte in the window
cp_ptr:   .res 2                  ; source of a match being copied
r_cur:    .res 2                  ; the row being built     (+Y)
r_left:   .res 2                  ;   ... one pixel to the left
r_up:     .res 2                  ; the row above           (+Y)
r_ul:     .res 2                  ;   ... one pixel to the left
f_ptr:    .res 2                  ; the pixel being sampled
m_ptr:    .res 2                  ; entry in the colour table
h_cl:     .res 2                  ; Huffman table being built:
h_ch:     .res 2                  ;   counts (low/high bytes),
h_ol:     .res 2                  ;   offsets (low/high bytes) and
h_oh:     .res 2                  ;   symbols (low/high bytes)
h_sl:     .res 2
h_sh:     .res 2
f_src:    .res 2                  ; next window byte to unfilter
l_ptr:    .res 2                  ; general pointer
s_ptr:    .res 2                  ; general pointer
bitbuf:   .res 1                  ; bits not yet used (see getbit)
.popseg

.pushseg
.segment "BSS"
pv_want:    .res 1                ; file record to show ($FF = none)
pv_timer:   .res 1                ; frames until decoding starts
pv_i:       .res 1
pv_namelen: .res 1

png_sp:     .res 1                ; stack pointer, for png_return
in_left:    .res 2                ; bytes left in inbuf
in_eof:     .res 1                ; not 0 when the file is all read
in_err:     .res 1                ; error to give if reading fails
ch_len:     .res 4                ; bytes left in this chunk (LSB 1st)
ch_type:    .res 4                ; this chunk's type
u32:        .res 4                ; a number read from the file

img_w:      .res 2                ; picture width and height
img_h:      .res 2
depth:      .res 1                ; bit depth
ctype:      .res 1                ; colour type
bits:       .res 1                ; bits per pixel
bpp:        .res 1                ; bytes per pixel (at least 1)
samp:       .res 1                ; bytes per value: 1 or 2 (16-bit)
has_alpha:  .res 1                ; not 0: colour type 4 or 6
low_mask:   .res 1                ; for depths 1-4: (1 << depth) - 1
exp_off:    .res 1                ; ... and where its grey table is
rowbytes:   .res 2                ; bytes in a row (without filter)
fetch_vec:  .res 2                ; routine that reads one pixel

out_w:      .res 2                ; size of the picture on screen
out_h:      .res 2
x_off:      .res 1                ; where it starts in the panel
oy:         .res 2                ; next output row
sy:         .res 2                ; source row being decoded
nsy:        .res 2                ; source row the next output row
nrem:       .res 2                ;   comes from, and the remainder
qstep:      .res 2                ; nsy grows by qstep and nrem by
rstep:      .res 2                ;   rstep for each output row
den:        .res 2                ; nrem wraps at den
row_cur:    .res 2                ; the two row buffers: the one
row_prev:   .res 2                ;   being built and the one above
rleft:      .res 2                ; bytes of the row still to come
                                  ;   (0: the filter byte is next)
pending:    .res 2                ; bytes in the window not yet
f_bank:     .res 1                ;   unfiltered, from f_bank:f_src
run_n:      .res 2                ; bytes in this run (1-256)
run_vec:    .res 2                ; filter loop for this row
va:         .res 1
vb:         .res 1
vc:         .res 1
dpa:        .res 1
dpb:        .res 1
dpc:        .res 1
win_bank:   .res 1                ; bank of win_ptr
cp_bank:    .res 1                ; bank of cp_ptr
pv_next:    .res 1                ; next free palette entry
pr:         .res 1                ; the sampled pixel's red, green,
pg:         .res 1                ;   blue (0-255) and alpha
pb:         .res 1
pa:         .res 1
cur_sh:     .res 1                ; its bit shift (depths 1-4)
red4:         .res 1                ; red, green, blue cut to 0-15
green4:         .res 1
blue4:         .res 1
best:       .res 1                ; closest colour search
best_d:     .res 2
dist_t:     .res 2

z_last:     .res 1                ; 1 in the last deflate block
val:        .res 2                ; result of getbits
gmask:      .res 2
diff:       .res 2                ; Huffman decoding (see DECODER)
sym:        .res 2                ; the decoded symbol
mlen:       .res 2                ; a match's length and distance
mdist:      .res 2
cn:         .res 2                ; construct: number of lengths
symc:       .res 2                ;   symbol counter
nlen:       .res 2                ; dynamic block: lit/length codes,
ndist:      .res 1                ;   distance codes, total
ntotal:     .res 2
li:         .res 2                ;   length being read
rep:        .res 1                ;   repeat count
repv:       .res 1                ;   repeated length
m32:        .res 4                ; multiply / divide workspace
m_a:        .res 2
m_b:        .res 2
d_num:      .res 4
d_div:      .res 2
d_rem:      .res 2
tsx_save:   .res 1

; Huffman tables. Each has the number of codes of each length
; (1-15; 16-bit counts, low and high bytes), how many symbols have
; shorter codes than each length (offsets), and the symbols, sorted
; by code (16-bit, low and high bytes).
lit_cl:     .res 16
lit_ch:     .res 16
lit_ol:     .res 16
lit_oh:     .res 16
lit_sl:     .res 288
lit_sh:     .res 288
dst_cl:     .res 16
dst_ch:     .res 16
dst_ol:     .res 16
dst_oh:     .res 16
dst_sl:     .res 32
dst_sh:     .res 32
cl_cl:      .res 16
cl_ch:      .res 16
cl_ol:      .res 16
cl_oh:      .res 16
cl_sl:      .res 19
cl_sh:      .res 19
offs_lo:    .res 16               ; construct workspace
offs_hi:    .res 16
lengths:    .res 320              ; code lengths for construct

col_lo:     .res PV_W             ; for each output column: byte
col_hi:     .res PV_W             ;   offset of its source pixel in
col_sh:     .res PV_W             ;   the row, and bit shift
pv_line:    .res PV_W             ; one output row of the panel
inbuf:      .res 512              ; bytes read from the file
rowbuf0:    .res 8+ROW_MAX        ; the two rows. The 8 bytes in
rowbuf1:    .res 8+ROW_MAX        ;   front are always 0, so the
                                  ;   pixel "left of" the first is 0
.popseg

;==================================================================
; Setting up and choosing what to show
;==================================================================

;------------------------------------------------------------------
; preview_init - set up layer 0 for the preview panel (see the top
; of this file) and fill the panel with grey.
;------------------------------------------------------------------
preview_init:
   ; the map: all tile 0 ...
   VERA_SET_ADDR MAP_VRAM, 1
   ldy #64                        ; 64 pages of 256 bytes = 16 KB
   ldx #0
:  stz VERA_data0
   inx
   bne :-
   dey
   bne :-

   ; ... except the panel's cells: tile 1 + row*16 + column
   ; (2 bytes per cell: tile number low byte, then bits 8-9)
   lda #1
   sta tmp                        ; tmp/tmp+1 = tile number
   stz tmp+1
   ldy #LIST_TOP                  ; Y = screen row
@maprow:
   ; address of cell (PREV_X, Y) = MAP_VRAM + Y*256 + PREV_X*2
   lda #PREV_X*2
   sta VERA_addr_low
   tya
   clc
   adc #>MAP_VRAM
   sta VERA_addr_high
   lda #$10 | ^MAP_VRAM           ; increment 1
   sta VERA_addr_bank
   ldx #PREV_W
:  lda tmp
   sta VERA_data0
   lda tmp+1
   sta VERA_data0
   inc tmp
   bne :+
   inc tmp+1
:  dex
   bne :--
   iny
   cpy #LIST_TOP+LIST_ROWS
   bne @maprow

   ; tile 0: 64 see-through pixels
   VERA_SET_ADDR TILE_VRAM, 1
   ldx #64
:  stz VERA_data0
   dex
   bne :-
   jsr pv_clear_tiles             ; the panel's tiles: grey

   ; layer 0: map 64 high (1) x 128 wide (2), tiles, 8 bits/pixel (3)
   lda #(1 << 6) | (2 << 4) | 3
   sta VERA_L0_config
   lda #<(MAP_VRAM >> 9)
   sta VERA_L0_mapbase
   lda #<((TILE_VRAM >> 11) << 2) ; 8x8 tiles
   sta VERA_L0_tilebase
   stz VERA_L0_hscroll_l
   stz VERA_L0_hscroll_h
   stz VERA_L0_vscroll_l
   stz VERA_L0_vscroll_h
   lda VERA_dc_video
   ora #$10                       ; bit 4: layer 0 on
   sta VERA_dc_video

   lda #$FF
   sta pv_want                    ; nothing shown
   stz pv_timer
   rts

;------------------------------------------------------------------
; preview_off - switch layer 0 off again (before going to BASIC)
;------------------------------------------------------------------
preview_off:
   lda VERA_dc_video
   and #$EF
   sta VERA_dc_video
   rts

;------------------------------------------------------------------
; pv_clear_tiles - fill all the panel's tiles with the background
;------------------------------------------------------------------
pv_clear_tiles:
   VERA_SET_ADDR (TILE_VRAM + 64), 1
   ldy #>(PV_TILES*64)            ; 168 pages of 256 bytes
   .assert <(PV_TILES*64) = 0, error, "tile area must be whole pages"
   lda #PV_BG
   ldx #0
:  sta VERA_data0
   inx
   bne :-
   dey
   bne :-
   rts

;------------------------------------------------------------------
; preview_message - show a message on the panel's bottom row
; In: A/X = address of a PETSCII string (low/high), or X = 0 to
;     clear the row
;------------------------------------------------------------------
preview_message:
   sta sptr
   stx sptr+1
   ldx #PREV_X
   ldy #PV_MSG_ROW
   jsr set_cursor
   lda #PREV_W
   sta remain
   lda #COL_PV_TEXT
   sta cur_color
   lda sptr+1
   beq :+
   jsr put_string
:  jmp pad_field

;------------------------------------------------------------------
; preview_update - called whenever the file list is redrawn: works
; out which picture should be shown and, if it has changed, blanks
; the panel and starts the countdown to decoding it.
;------------------------------------------------------------------
preview_update:
   jsr pv_find                    ; A = record to show
   cmp pv_want
   beq @done                      ; no change
   sta pv_want
   jsr pv_clear_tiles
   ldx #0
   jsr preview_message            ; clear any message
   stz pv_timer
   lda pv_want
   cmp #$FF
   beq @done                      ; nothing to show
   lda #PREVIEW_DELAY
   sta pv_timer
@done:
   rts

;------------------------------------------------------------------
; pv_find - which file should be previewed?
; Out: A = its record number, or $FF if none.
; The highlighted file if it is a PNG, else the first PNG listed.
;------------------------------------------------------------------
pv_find:
   lda file_sel
   cmp #$FF
   beq @first
   jsr pv_is_png
   bcs @done
@first:
   stz pv_i
@loop:
   lda pv_i
   cmp file_count
   beq @none
   jsr pv_is_png
   bcs @done
   inc pv_i
   bra @loop
@none:
   lda #$FF
@done:
   rts

; pv_is_png - is file A (position in the sorted list) a PNG?
; Out: C = 1 and A = its record number if it is
pv_is_png:
   tax
   lda file_order,x
   pha
   jsr file_ptr
   ldy #REC_FLAGS
   lda (ptr),y
   stz RAM_BANK
   and #FLAG_PNG
   cmp #1                         ; C = 1 if the flag was set
   pla
   rts

;------------------------------------------------------------------
; preview_tick - called every frame by the main loop: counts down
; and decodes the picture when the count reaches 0.
;------------------------------------------------------------------
preview_tick:
   lda pv_timer
   beq @done
   dec pv_timer
   bne @done

   ; load the file's record, to get its name
   lda pv_want
   jsr file_ptr
   jsr load_rec
   ldx #0
:  lda recbuf+REC_NAME,x
   beq :+
   inx
   bra :-
:  stx pv_namelen

   jsr pv_clear_tiles             ; (rows left by an interrupted try)
   lda #<str_pv_loading
   ldx #>str_pv_loading
   jsr preview_message
   jsr png_decode                 ; A = result
   cmp #PNG_ABORT
   beq @abort
   cmp #PNG_OK
   beq @ok
   ; an error: blank the panel and say what went wrong
   pha
   jsr pv_clear_tiles
   pla
   asl
   tax
   lda pv_errors-2*PNG_ERR_OPEN,x
   pha
   lda pv_errors-2*PNG_ERR_OPEN+1,x
   tax
   pla
   jmp preview_message
@ok:
   ldx #0                         ; clear "Loading..."
   jmp preview_message
@abort:
   ; interrupted: try again once things have settled down (if the
   ; key or click changes the selection, preview_update starts
   ; the count again anyway)
   lda #PREVIEW_DELAY
   sta pv_timer
@done:
   rts

str_pv_loading:  .byte "Loading...", 0
str_pv_open:     .byte "Can't open file", 0
str_pv_notpng:   .byte "Not a PNG file", 0
str_pv_type:     .byte "Unknown PNG type", 0
str_pv_ilace:    .byte "Interlaced PNG", 0
str_pv_size:     .byte "Image too wide", 0
str_pv_data:     .byte "Damaged PNG", 0
pv_errors:
   .word str_pv_open, str_pv_notpng, str_pv_type
   .word str_pv_ilace, str_pv_size, str_pv_data

;==================================================================
; png_decode - decode the PNG named in recbuf (pv_namelen long)
; into the panel.
; Out: A = PNG_OK, PNG_ABORT or one of the PNG_ERR_ codes
;
; Errors can be found deep inside the decoder, so instead of every
; routine checking for them, png_return puts the stack pointer back
; to what it was when png_decode started and returns from there.
;==================================================================
png_decode:
   tsx
   stx png_sp
   stz in_left
   stz in_left+1
   stz in_eof
   lda #PNG_ERR_OPEN
   sta in_err

   ; OPEN 3,8,3,"name"
   lda pv_namelen
   ldx #<(recbuf+REC_NAME)
   ldy #>(recbuf+REC_NAME)
   jsr SETNAM
   lda #LFN_PNG
   ldx #DISK_DEVICE
   ldy #3
   jsr SETLFS
   jsr OPEN
   bcs @open_fail
   ldx #LFN_PNG
   jsr CHKIN
   bcc :+
@open_fail:
   lda #PNG_ERR_OPEN
   jmp png_return
:
   ; the signature
   lda #PNG_ERR_NOTPNG            ; from now on a short file is
   sta in_err                     ;   "not a PNG"
   ldx #0
:  jsr get_byte
   cmp png_sig,x
   bne @not_png
   inx
   cpx #8
   bne :-

   ; the first chunk must be IHDR
   jsr chunk_header
   ldx #<type_ihdr
   jsr is_type
   bne @not_png
   jsr read_ihdr                  ; (fails if it doesn't like it)
   lda #PNG_ERR_DATA              ; a short file now is "damaged"
   sta in_err

   ; default palette: all black and opaque
   lda #MAP_BANK
   sta RAM_BANK
   ldx #0
:  stz PLTE_R,x
   stz PLTE_G,x
   stz PLTE_B,x
   lda #$FF
   sta PLTE_A,x
   inx
   bne :-

   ; the chunks before the picture data
@chunk:
   jsr chunk_header
   ldx #<type_idat
   jsr is_type
   beq @idat
   ldx #<type_plte
   jsr is_type
   bne :+
   jsr read_plte
   bra @chunk
:  ldx #<type_trns
   jsr is_type
   bne :+
   lda ctype
   cmp #3
   bne :+                         ; only used for palette pictures
   jsr read_trns
   bra @chunk
:  ldx #<type_iend
   jsr is_type
   beq @no_data
   jsr chunk_skip                 ; anything else: skip it
   bra @chunk

@not_png:
   lda #PNG_ERR_NOTPNG
   jmp png_return
@no_data:
   lda #PNG_ERR_DATA
   jmp png_return

@idat:
   jsr setup_picture              ; sizes, tables, rows, colours
   jsr inflate                    ; decode; row_done returns via
                                  ;   png_return once the picture
                                  ;   is finished
   lda #PNG_OK                    ; data ended early: show what we got
   ; fall through

;------------------------------------------------------------------
; png_return - finish decoding: close the file and return from
; png_decode with result A, from wherever we are.
;------------------------------------------------------------------
png_return:
   ldx png_sp
   txs                            ; back to png_decode's stack level
   pha
   stz RAM_BANK
   jsr CLRCHN
   lda #LFN_PNG
   jsr CLOSE
   pla
   rts

png_sig: .byte $89, $50, $4E, $47, $0D, $0A, $1A, $0A

; Chunk types, as ASCII bytes (the assembler would turn letters in
; quotes into PETSCII). Kept in one page so is_type can use X.
type_ihdr: .byte $49, $48, $44, $52   ; IHDR
type_idat: .byte $49, $44, $41, $54   ; IDAT
type_plte: .byte $50, $4C, $54, $45   ; PLTE
type_trns: .byte $74, $52, $4E, $53   ; tRNS
type_iend: .byte $49, $45, $4E, $44   ; IEND
.assert >type_ihdr = >type_iend, error, "chunk types must be in one page"

;------------------------------------------------------------------
; is_type - is this chunk's type the one at (type_ihdr page):X?
; Out: Z = 1 if it is
;------------------------------------------------------------------
is_type:
   ldy #0
:  lda ch_type,y
   cmp type_ihdr - <type_ihdr,x   ; = the byte at that page + X
   bne @done
   inx
   iny
   cpy #4
   bne :-
@done:
   rts

;==================================================================
; Reading the file
;==================================================================

;------------------------------------------------------------------
; get_byte - the next byte of the file in A. Preserves X and Y.
; Bytes are read 512 at a time into inbuf with MACPTR (much faster
; than one at a time with CHRIN).
;------------------------------------------------------------------
get_byte:
   lda in_left
   bne @take
   lda in_left+1
   beq @refill
   dec in_left+1
@take:
   dec in_left
   lda (in_ptr)
   inc in_ptr
   beq :+
   rts
:  inc in_ptr+1
   rts

@refill:
   phx
   phy
   lda RAM_BANK
   pha
   stz RAM_BANK                   ; bank 0 for the KERNAL
   lda in_eof
   bne @fail                      ; nothing left to read
   lda #0                         ; 0 = as many as it likes (<= 512)
   ldx #<inbuf
   ldy #>inbuf
   clc                            ; C = 0: step through memory
   jsr MACPTR
   bcs @slow                      ; MACPTR not supported here
   stx in_left
   sty in_left+1
@got:
   jsr READST
   tax
   and #$BF                       ; anything except end of file
   bne @fail                      ;   is an error
   txa
   and #$40
   sta in_eof
   lda in_left
   ora in_left+1
   beq @fail                      ; read nothing
   lda #<inbuf
   sta in_ptr
   lda #>inbuf
   sta in_ptr+1
   pla
   sta RAM_BANK
   ply
   plx
   bra get_byte

@slow:                            ; one byte at a time, up to 255
   stz in_left
   stz in_left+1
:  jsr CHRIN
   ldx in_left
   sta inbuf,x
   inc in_left
   jsr READST
   bne @got
   lda in_left
   cmp #255
   bne :-
   bra @got

@fail:
   lda in_err
   jmp png_return

;------------------------------------------------------------------
; chunk_header - read a chunk's length (into ch_len, low byte
; first) and type (into ch_type)
;------------------------------------------------------------------
chunk_header:
   jsr read_u32                   ; u32 is high byte first:
   lda u32+3                      ;   turn it round
   sta ch_len
   lda u32+2
   sta ch_len+1
   lda u32+1
   sta ch_len+2
   lda u32
   sta ch_len+3
   ldx #0
:  jsr get_byte
   sta ch_type,x
   inx
   cpx #4
   bne :-
   rts

;------------------------------------------------------------------
; read_u32 - read a 4 byte number into u32 (high byte first, as it
; is in the file)
;------------------------------------------------------------------
read_u32:
   ldx #0
:  jsr get_byte
   sta u32,x
   inx
   cpx #4
   bne :-
   rts

;------------------------------------------------------------------
; chunk_byte - the next byte of the chunk's data (the caller makes
; sure there is one). Counts ch_len down. Preserves X and Y.
;------------------------------------------------------------------
chunk_byte:
   lda ch_len
   bne @d0
   lda ch_len+1
   bne @d1
   lda ch_len+2
   bne @d2
   dec ch_len+3
@d2:
   dec ch_len+2
@d1:
   dec ch_len+1
@d0:
   dec ch_len
   jmp get_byte

; chunk_empty - Z = 1 if the chunk has no bytes left. Preserves X/Y.
chunk_empty:
   lda ch_len
   ora ch_len+1
   ora ch_len+2
   ora ch_len+3
   rts

;------------------------------------------------------------------
; chunk_skip - skip the rest of the chunk, and its CRC
;------------------------------------------------------------------
chunk_skip:
   jsr chunk_empty
   beq :+
   jsr chunk_byte
   bra chunk_skip
:  jmp read_u32                   ; the CRC

;------------------------------------------------------------------
; read_ihdr - read the IHDR chunk and check we can show the picture
;------------------------------------------------------------------
read_ihdr:
   ; width and height must fit in 16 bits
   jsr read_u32
   lda u32
   ora u32+1
   beq @w_ok
   jmp @too_big
@w_ok:
   lda u32+2
   sta img_w+1
   lda u32+3
   sta img_w
   jsr read_u32
   lda u32
   ora u32+1
   bne @too_big
   lda u32+2
   sta img_h+1
   lda u32+3
   sta img_h
   jsr get_byte
   sta depth
   jsr get_byte
   sta ctype
   jsr get_byte                   ; compression method (always 0)
   jsr get_byte                   ; filter method (always 0)
   jsr get_byte                   ; interlace method
   cmp #0
   beq :+
   lda #PNG_ERR_INTERLACE
   jmp png_return
:  jsr read_u32                   ; the CRC

   lda img_w
   ora img_w+1
   beq @bad
   lda img_h
   ora img_h+1
   beq @bad

   ; Which bit depths go with which colour types, and how many
   ; values make up a pixel:
   ;   type 0 grey        1,2,4,8,16   1 value
   ;   type 2 RGB         8,16         3
   ;   type 3 palette     1,2,4,8      1
   ;   type 4 grey+alpha  8,16         2
   ;   type 6 RGBA        8,16         4
   lda ctype
   cmp #7
   bcs @bad
   tax
   lda ct_values,x
   beq @bad                       ; types 1 and 5 don't exist
   sta tmp                        ; tmp = values per pixel
   lda ct_alpha,x
   sta has_alpha
   lda depth                      ; depth 16 allowed?
   cmp #16
   bne :+
   cpx #3
   beq @bad                       ; not for palettes
   bra @depth_ok
:  cmp #8
   beq @depth_ok
   cmp #1                         ; 1, 2, 4: only types 0 and 3
   beq :+
   cmp #2
   beq :+
   cmp #4
   bne @bad
:  cpx #0
   beq @depth_ok
   cpx #3
   beq @depth_ok
@bad:                             ; (here, so the branches reach)
   lda #PNG_ERR_TYPE
   jmp png_return
@too_big:
   lda #PNG_ERR_SIZE
   jmp png_return
@depth_ok:
   ; bits per pixel = depth * values (at most 64)
   lda depth
   ldx tmp
   stz bits
:  clc
   adc bits
   sta bits
   lda depth
   dex
   bne :-
   ; bytes per pixel for the filters: bits / 8, at least 1
   lda bits
   lsr
   lsr
   lsr
   bne :+
   lda #1
:  sta bpp
   ; bytes per value: 2 if 16-bit
   ldx #1
   lda depth
   cmp #16
   bne :+
   inx
:  stx samp

   ; bytes per row = (width * bits + 7) / 8, at most ROW_MAX
   lda img_w
   sta m_a
   lda img_w+1
   sta m_a+1
   lda bits
   sta m_b
   stz m_b+1
   jsr mul16                      ; m32 = width * bits
   lda m32
   clc
   adc #7
   sta m32
   bcc :+
   inc m32+1
   bne :+
   inc m32+2
:  ldx #3                         ; divide by 8
:  lsr m32+2
   ror m32+1
   ror m32
   dex
   bne :-
   lda m32+2
   bne @too_big
   lda m32
   sta rowbytes
   lda m32+1
   sta rowbytes+1
   cmp #>ROW_MAX                  ; rowbytes <= ROW_MAX?
   bcc @size_ok
   bne @row_big
   lda rowbytes                   ; (ROW_MAX is a whole number of
   beq @size_ok                   ;   pages)
@row_big:
   jmp @too_big
@size_ok:

   ; choose the routine that reads one pixel
   lda ctype
   asl
   tax
   lda depth
   cmp #8
   bcs :+                         ; 8 or 16 bits
   txa                            ; 1, 2 or 4 bits: the second row
   clc
   adc #14
   tax
:  lda fetch_tab,x
   sta fetch_vec
   lda fetch_tab+1,x
   sta fetch_vec+1
   ; for 1-4 bits: the mask and the grey expansion table
   ldx depth
   lda low_masks,x
   sta low_mask
   lda exp_offs,x
   sta exp_off
   rts

ct_values: .byte 1, 0, 3, 1, 2, 0, 4   ; values per pixel by type
ct_alpha:  .byte 0, 0, 0, 0, 1, 0, 1   ; has an alpha value
; pixel readers, by colour type: 8/16-bit depths, then (14 bytes
; later) 1/2/4-bit depths
fetch_tab:
   .word fetch_grey, 0, fetch_rgb, fetch_idx8, fetch_grey, 0, fetch_rgb
   .word fetch_grey_low, 0, 0, fetch_idx_low, 0, 0, 0
low_masks: .byte 0, $01, $03, 0, $0F   ; by depth 0-4
exp_offs:  .byte 0, 0, 2, 0, 6         ; where exp_tab's part starts
; grey levels for depths 1, 2 and 4, spread over 0-255
exp_tab:
   .byte $00, $FF
   .byte $00, $55, $AA, $FF
   .byte $00, $11, $22, $33, $44, $55, $66, $77
   .byte $88, $99, $AA, $BB, $CC, $DD, $EE, $FF

;------------------------------------------------------------------
; read_plte - read the palette chunk: up to 256 R, G, B triples
;------------------------------------------------------------------
read_plte:
   ldx #0
@next:
   lda ch_len+3                   ; at least 3 bytes left?
   ora ch_len+2
   ora ch_len+1
   bne :+
   lda ch_len
   cmp #3
   bcc @done
:  lda #MAP_BANK
   sta RAM_BANK
   jsr chunk_byte
   sta PLTE_R,x
   jsr chunk_byte
   sta PLTE_G,x
   jsr chunk_byte
   sta PLTE_B,x
   inx
   bne @next                      ; stop after 256
@done:
   jmp chunk_skip

;------------------------------------------------------------------
; read_trns - read the transparency chunk of a palette picture:
; one alpha value for each palette entry (up to 256)
;------------------------------------------------------------------
read_trns:
   ldx #0
@next:
   jsr chunk_empty
   beq @done
   lda #MAP_BANK
   sta RAM_BANK
   jsr chunk_byte
   sta PLTE_A,x
   inx
   bne @next
@done:
   jmp chunk_skip

;------------------------------------------------------------------
; get_zbyte - the next byte of compressed data. When an IDAT chunk
; runs out it carries on with the next one. Preserves X and Y.
;------------------------------------------------------------------
get_zbyte:
   jsr chunk_empty
   beq @next
   jmp chunk_byte
@next:
   phx
   phy
   jsr read_u32                   ; this chunk's CRC
   jsr chunk_header
   ldx #<type_idat
   jsr is_type
   beq :+
   lda #PNG_ERR_DATA              ; the data stopped too soon
   jmp png_return
:  ply
   plx
   bra get_zbyte                  ; (the new chunk may be empty)

;==================================================================
; Getting ready to decode the picture
;==================================================================

;------------------------------------------------------------------
; setup_picture - work out the picture's size on screen and which
; source pixels make it up; clear the rows, colours and window.
;------------------------------------------------------------------
setup_picture:
   ; Fit the picture in PV_W x PV_H, keeping its shape:
   ;   if width*PV_H >= height*PV_W (wider than the panel):
   ;       out_w = PV_W, out_h = height*PV_W/width (rounded)
   ;   else
   ;       out_h = PV_H, out_w = width*PV_H/height
   lda img_w
   sta m_a
   lda img_w+1
   sta m_a+1
   lda #<PV_H
   sta m_b
   lda #>PV_H
   sta m_b+1
   jsr mul16
   ldx #3
:  lda m32,x
   sta d_num,x                    ; d_num = width * PV_H (for later)
   dex
   bpl :-
   lda img_h
   sta m_a
   lda img_h+1
   sta m_a+1
   lda #<PV_W
   sta m_b
   lda #>PV_W
   sta m_b+1
   jsr mul16                      ; m32 = height * PV_W
   ; compare d_num with m32 (32-bit): C = 1 if d_num >= m32
   lda d_num
   cmp m32
   lda d_num+1
   sbc m32+1
   lda d_num+2
   sbc m32+2
   lda d_num+3
   sbc m32+3
   bcc @tall

   ; wide: out_w = PV_W, out_h = (height*PV_W + width/2) / width
   lda #<PV_W
   sta out_w
   lda #>PV_W
   sta out_w+1
   ldx #3
:  lda m32,x
   sta d_num,x
   dex
   bpl :-
   lda img_w
   sta d_div
   lda img_w+1
   sta d_div+1
   jsr add_half_div
   jsr div32
   lda d_num
   sta out_h
   lda d_num+1
   sta out_h+1
   bra @sized

@tall:
   ; tall: out_h = PV_H, out_w = (width*PV_H + height/2) / height
   ; (d_num still holds width*PV_H)
   lda #<PV_H
   sta out_h
   lda #>PV_H
   sta out_h+1
   lda img_h
   sta d_div
   lda img_h+1
   sta d_div+1
   jsr add_half_div
   jsr div32
   lda d_num
   sta out_w
   lda d_num+1
   sta out_w+1

@sized:
   ; never 0 (a very long thin picture)
   lda out_w
   ora out_w+1
   bne :+
   inc out_w
:  lda out_h
   ora out_h+1
   bne :+
   inc out_h
:  ; centre it across the panel: x_off = (PV_W - out_w) / 2
   lda #PV_W
   sec
   sbc out_w
   lsr
   sta x_off

   ; ---- which source column each output column comes from ----
   ; Output column ox shows source column (2*ox+1)*width/(2*out_w),
   ; the source pixel under the middle of the output pixel. Adding
   ; up as we go: sx starts at width/(2*out_w) and grows by
   ; width/out_w each time, the remainders carried along.
   lda img_w
   ldx img_w+1
   ldy #0                         ; 0 = columns
   jsr dda_setup
   stz tmp+3                      ; tmp+3 = ox
@col:
   ; byte offset and shift of source column nsy (used for columns
   ; here) in a row
   lda bits
   cmp #8
   bcc @lowbits
   ; 8+ bits per pixel: offset = sx * bits/8
   lda nsy
   sta m_a
   lda nsy+1
   sta m_a+1
   lda bpp
   sta m_b
   stz m_b+1
   jsr mul16
   ldx tmp+3
   lda m32
   sta col_lo,x
   lda m32+1
   sta col_hi,x
   stz col_sh,x
   bra @col_next
@lowbits:
   ; 1, 2 or 4 bits: bit position = sx * depth; offset = that / 8;
   ; the pixel is in the byte's bits 7.. downwards, so the shift
   ; that brings it to the bottom is 8 - depth - (position mod 8)
   lda nsy
   sta m32
   lda nsy+1
   sta m32+1
   stz m32+2
   lda depth
:  lsr
   beq :+
   asl m32                        ; times 2 (depth 2) or 4 (depth 4)
   rol m32+1
   rol m32+2
   bra :-
:  ldx tmp+3
   lda m32
   and #7
   sta tmp
   lda #8
   sec
   sbc depth
   sec
   sbc tmp
   sta col_sh,x
   ldy #3
:  lsr m32+2
   ror m32+1
   ror m32
   dey
   bne :-
   lda m32
   sta col_lo,x
   lda m32+1
   sta col_hi,x
@col_next:
   jsr dda_step
   inc tmp+3
   lda tmp+3
   cmp out_w
   beq :+
   jmp @col
:
   ; ---- the same for rows, worked out as the rows arrive ----
   lda img_h
   ldx img_h+1
   ldy #1                         ; 1 = rows
   jsr dda_setup
   stz oy
   stz oy+1
   stz sy
   stz sy+1

   ; ---- colours: none given out yet ----
   lda #PV_FIRST_COL
   sta pv_next
   lda #MAP_BANK
   sta RAM_BANK
   lda #<CMAP
   sta l_ptr
   lda #>CMAP
   sta l_ptr+1
   ldx #16                        ; 16 pages = 4096 bytes
   ldy #0
   lda #0
:  sta (l_ptr),y
   iny
   bne :-
   inc l_ptr+1
   dex
   bne :-

   ; ---- rows: the one "above" the first row is all 0 ----
   lda #<(rowbuf0+8)
   sta row_cur
   lda #>(rowbuf0+8)
   sta row_cur+1
   lda #<(rowbuf1+8)
   sta row_prev
   lda #>(rowbuf1+8)
   sta row_prev+1
   ldx #7
:  stz rowbuf0,x                  ; the 0 bytes in front of each row
   stz rowbuf1,x
   dex
   bpl :-
   lda row_prev
   sta l_ptr
   lda row_prev+1
   sta l_ptr+1
   ldx #>ROW_MAX                  ; ROW_MAX/256 pages
   ldy #0
   lda #0
:  sta (l_ptr),y
   iny
   bne :-
   inc l_ptr+1
   dex
   bne :-

   ; ---- the window starts at the beginning of its first bank ----
   lda #WIN_BANK
   sta win_bank
   sta f_bank
   stz win_ptr
   stz f_src
   lda #>RAM_WIN
   sta win_ptr+1
   sta f_src+1
   stz pending
   stz pending+1

   jmp row_begin

;------------------------------------------------------------------
; add_half_div - d_num += d_div / 2 (so that dividing rounds)
;------------------------------------------------------------------
add_half_div:
   lda d_div+1
   lsr
   sta tmp+1
   lda d_div
   ror
   clc
   adc d_num
   sta d_num
   lda tmp+1
   adc d_num+1
   sta d_num+1
   bcc :+
   inc d_num+2
   bne :+
   inc d_num+3
:  rts

;------------------------------------------------------------------
; dda_setup - get ready to step through source positions
; In: A/X = source size (width or height), Y = 0 for columns (uses
;     out_w), 1 for rows (uses out_h)
;
; Output position o uses source position (2*o+1)*size/(2*out).
; nsy/nrem = that for o = 0: size / (2*out), and the remainder;
; qstep/rstep = how much they grow for each o: size/out, and
; 2*(size mod out); den = 2*out, where the remainder wraps.
;------------------------------------------------------------------
dda_setup:
   sta d_num
   stx d_num+1
   stz d_num+2
   stz d_num+3
   lda out_w
   ldx out_w+1
   cpy #0
   beq :+
   lda out_h
   ldx out_h+1
:  sta tmp                        ; tmp/tmp+1 = out
   stx tmp+1
   ; qstep, rstep = size / out, 2 * (size mod out)
   sta d_div
   stx d_div+1
   jsr div32                      ; (keeps the size in dda_size)
   lda d_num
   sta qstep
   lda d_num+1
   sta qstep+1
   lda d_rem
   asl
   sta rstep
   lda d_rem+1
   rol
   sta rstep+1
   ; den = 2 * out
   lda tmp
   asl
   sta den
   sta d_div
   lda tmp+1
   rol
   sta den+1
   sta d_div+1
   ; nsy, nrem = size / den, size mod den
   lda dda_size
   sta d_num
   lda dda_size+1
   sta d_num+1
   stz d_num+2
   stz d_num+3
   jsr div32
   lda d_num
   sta nsy
   lda d_num+1
   sta nsy+1
   lda d_rem
   sta nrem
   lda d_rem+1
   sta nrem+1
   rts

;------------------------------------------------------------------
; dda_step - move on to the next output position
;------------------------------------------------------------------
dda_step:
   lda nsy
   clc
   adc qstep
   sta nsy
   lda nsy+1
   adc qstep+1
   sta nsy+1
   lda nrem
   clc
   adc rstep
   sta nrem
   lda nrem+1
   adc rstep+1
   sta nrem+1
   ; if nrem >= den: nrem -= den, nsy += 1
   lda nrem
   cmp den
   lda nrem+1
   sbc den+1
   bcc @done
   sta nrem+1
   lda nrem
   sbc den                        ; (carry is still set)
   sta nrem
   inc nsy
   bne @done
   inc nsy+1
@done:
   rts

;------------------------------------------------------------------
; mul16 - m32 = m_a * m_b (16 x 16 bits = 32 bits)
;------------------------------------------------------------------
mul16:
   stz m32+2
   stz m32+3
   lda m_a
   sta m32
   lda m_a+1
   sta m32+1
   ; shift-and-add: for each of the 16 bits of m_a (shifted out of
   ; the bottom of m32), add m_b into the top half if it is 1
   ldx #16
   lsr m32+1
   ror m32
@loop:
   bcc :+
   lda m32+2
   clc
   adc m_b
   sta m32+2
   lda m32+3
   adc m_b+1
   sta m32+3
:  ror m32+3
   ror m32+2
   ror m32+1
   ror m32
   dex
   bne @loop
   rts

;------------------------------------------------------------------
; div32 - d_num = d_num / d_div, d_rem = the remainder
; (32 bits / 16 bits). Also keeps the original d_num's low 16 bits
; in dda_size.
;------------------------------------------------------------------
div32:
   lda d_num
   sta dda_size
   lda d_num+1
   sta dda_size+1
   stz d_rem
   stz d_rem+1
   ldx #32
@loop:
   asl d_num                      ; shift the next bit of the
   rol d_num+1                    ;   number into the remainder
   rol d_num+2
   rol d_num+3
   rol d_rem
   rol d_rem+1
   bcs @sub                       ; (remainder overflowed 16 bits)
   lda d_rem                      ; remainder >= divisor?
   cmp d_div
   lda d_rem+1
   sbc d_div+1
   bcc @next
@sub:
   lda d_rem
   sec
   sbc d_div
   sta d_rem
   lda d_rem+1
   sbc d_div+1
   sta d_rem+1
   inc d_num                      ; that bit of the answer is 1
@next:
   dex
   bne @loop
   rts

.pushseg
.segment "BSS"
dda_size: .res 2
.popseg

;==================================================================
; Undoing the filters, row by row
;==================================================================

;------------------------------------------------------------------
; row_begin - get ready for the next row: point r_cur and friends
; at the row buffers, and expect a filter byte first
;------------------------------------------------------------------
row_begin:
   lda row_cur
   sta r_cur
   sec
   sbc bpp
   sta r_left
   lda row_cur+1
   sta r_cur+1
   sbc #0
   sta r_left+1
   lda row_prev
   sta r_up
   sec
   sbc bpp
   sta r_ul
   lda row_prev+1
   sta r_up+1
   sbc #0
   sta r_ul+1
   stz rleft                      ; 0 = next comes a filter byte
   stz rleft+1
   rts

;------------------------------------------------------------------
; flush - undo the row filters on the bytes the decompressor has
; put in the window since last time (there are "pending" of them,
; starting at f_bank:f_src).
;
; It works in runs of up to 256 bytes that stay in one row and one
; bank, so the filter loops (run_none etc.) can be short and fast:
; each byte is just a few instructions, indexed by Y. Doing it this
; way, rather than a byte at a time as each one is decompressed,
; makes decoding about twice as fast.
;------------------------------------------------------------------
flush:
   lda pending
   ora pending+1
   bne :+
   rts                            ; all done
:  lda rleft
   ora rleft+1
   bne @data

   ; the start of a row: its filter byte
   lda f_bank
   sta RAM_BANK
   lda (f_src)
   cmp #5
   bcc :+
   lda #PNG_ERR_DATA
   jmp png_return
:  asl
   tax
   lda run_tab,x
   sta run_vec
   lda run_tab+1,x
   sta run_vec+1
   lda rowbytes
   sta rleft
   lda rowbytes+1
   sta rleft+1
   lda #1
   sta run_n
   stz run_n+1
   jsr adv_src
   bra flush

@data:
   ; run_n = the smallest of: pending, rleft, 256, and the bytes
   ; left in f_src's bank
   lda pending
   sta run_n
   lda pending+1
   sta run_n+1
   lda rleft
   cmp run_n
   lda rleft+1
   sbc run_n+1
   bcs :+                         ; rleft >= run_n
   lda rleft
   sta run_n
   lda rleft+1
   sta run_n+1
:  jsr cap_256
   lda f_src
   ldx f_src+1
   jsr cap_bank_end

   ; undo the filter on run_n bytes
   lda f_bank
   sta RAM_BANK
   jsr @run

   ; move everything on by run_n
   lda r_cur
   clc
   adc run_n
   sta r_cur
   lda r_cur+1
   adc run_n+1
   sta r_cur+1
   lda r_left
   clc
   adc run_n
   sta r_left
   lda r_left+1
   adc run_n+1
   sta r_left+1
   lda r_up
   clc
   adc run_n
   sta r_up
   lda r_up+1
   adc run_n+1
   sta r_up+1
   lda r_ul
   clc
   adc run_n
   sta r_ul
   lda r_ul+1
   adc run_n+1
   sta r_ul+1
   lda rleft
   sec
   sbc run_n
   sta rleft
   lda rleft+1
   sbc run_n+1
   sta rleft+1
   jsr adv_src
   lda rleft
   ora rleft+1
   bne :+
   jsr row_done                   ; the row is complete
:  jmp flush

@run:
   jmp (run_vec)

;------------------------------------------------------------------
; adv_src - f_src += run_n (moving on to the next window bank if
; needed), pending -= run_n
;------------------------------------------------------------------
adv_src:
   lda f_src
   clc
   adc run_n
   sta f_src
   lda f_src+1
   adc run_n+1
   cmp #>(RAM_WIN+RAM_WIN_SIZE)
   bcc :+
   sbc #>RAM_WIN_SIZE             ; (carry is set)
   inc f_bank
   ldx f_bank
   cpx #WIN_BANK+4
   bne :+
   ldx #WIN_BANK
   stx f_bank
:  sta f_src+1
   lda pending
   sec
   sbc run_n
   sta pending
   lda pending+1
   sbc run_n+1
   sta pending+1
   rts

;------------------------------------------------------------------
; cap_256      - run_n = at most 256
; cap_bank_end - run_n = at most the bytes from address A (low)/X
;                (high) to the end of the bank window ($C000)
;------------------------------------------------------------------
cap_256:
   lda run_n+1
   beq :+                         ; < 256
   stz run_n
   lda #1
   sta run_n+1
:  rts

cap_bank_end:
   cpx #>(RAM_WIN+RAM_WIN_SIZE)-1
   bne @done                      ; not in the last page: >= 256 left
   cmp #0
   beq @done                      ; exactly 256 left
   eor #$FF                       ; A = 256 - A (1-255)
   inc a
   ldx run_n+1
   bne @set                       ; run_n = 256: more than that
   cmp run_n
   bcs @done
@set:
   sta run_n
   stz run_n+1
@done:
   rts

;------------------------------------------------------------------
; The filter loops: undo one filter on run_n bytes (1-256; a low
; byte of 0 means 256), from (f_src),y in the window to (r_cur),y in
; the row. In each:
;   (r_left),y = the same byte of the pixel to the left
;   (r_up),y   = the same byte in the row above
;   (r_ul),y   = the same byte above and to the left
; (for the first pixel, "left" is the 0 bytes in front of the row)
;------------------------------------------------------------------
run_tab: .word run_none, run_sub, run_up, run_avg, run_paeth

run_none:                         ; the bytes as they are
   ldy #0
:  lda (f_src),y
   sta (r_cur),y
   iny
   cpy run_n
   bne :-
   rts

run_sub:                          ; + left
   ldy #0
:  lda (f_src),y
   clc
   adc (r_left),y
   sta (r_cur),y
   iny
   cpy run_n
   bne :-
   rts

run_up:                           ; + above
   ldy #0
:  lda (f_src),y
   clc
   adc (r_up),y
   sta (r_cur),y
   iny
   cpy run_n
   bne :-
   rts

run_avg:                          ; + (left + above) / 2
   ldy #0
:  lda (r_left),y
   clc
   adc (r_up),y                   ; 9-bit sum: the 9th bit in C
   ror                            ; / 2 brings it back in
   clc
   adc (f_src),y
   sta (r_cur),y
   iny
   cpy run_n
   bne :-
   rts

run_paeth:
   ; a = left, b = above, c = above-left. With p = a + b - c:
   ;   pa = |p-a| = |b-c|, pb = |p-b| = |a-c|, pc = |p-c| = |(b-c)+(a-c)|
   ; Add a if pa is smallest, else b if pb <= pc, else c.
   ; If (b-c) and (a-c) have the same sign, pc = pa + pb, which is
   ; never the smallest, so the answer is just a if pa <= pb, else b.
   ; If not, pc = |pa - pb|.
   ldy #0
@byte:
   lda (r_ul),y
   sta vc
   lda (r_left),y
   sta va
   sec
   sbc vc                         ; a - c
   bcs @a_pos
   eor #$FF                       ; negative: make it positive
   inc a
   sta dpb                        ; pb = |a-c|  (a-c < 0)
   lda (r_up),y
   sta vb
   sec
   sbc vc                         ; b - c
   bcs @diff                      ; >= 0: different signs, A = pa
   eor #$FF
   inc a
   bra @same                      ; both < 0, A = pa
@a_pos:
   sta dpb                        ; pb = a-c  (>= 0)
   lda (r_up),y
   sta vb
   sec
   sbc vc                         ; b - c
   bcs @same                      ; both >= 0, A = pa
   eor #$FF
   inc a                          ; different signs, A = pa
@diff:
   sta dpa
   sec
   sbc dpb
   bcs :+
   eor #$FF
   inc a
:  sta dpc                        ; pc = |pa - pb|
   lda dpa
   cmp dpb
   beq :+
   bcs @not_a                     ; pa > pb
:  cmp dpc
   bcc @use_a                     ; pa < pc
   beq @use_a                     ; pa = pc
@not_a:
   lda dpb
   cmp dpc
   bcc @use_b                     ; pb < pc
   beq @use_b                     ; pb = pc
   lda vc
   bra @add
@same:
   cmp dpb                        ; a if pa <= pb, else b
   bcc @use_a
   bne @use_b
@use_a:
   lda va
   bra @add
@use_b:
   lda vb
@add:
   clc
   adc (f_src),y
   sta (r_cur),y
   iny
   cpy run_n
   beq :+
   jmp @byte
:  rts

;------------------------------------------------------------------
; row_done - a whole row has been decoded into row_cur.
; Draws every output row that comes from it, swaps the rows round,
; and gives up if a key has been pressed or the mouse clicked.
;------------------------------------------------------------------
row_done:
@emit:
   lda sy                         ; is this the source row of the
   cmp nsy                        ;   next output row?
   bne @emitted
   lda sy+1
   cmp nsy+1
   bne @emitted
   jsr emit_row
   jsr dda_step
   inc oy
   bne :+
   inc oy+1
:  lda oy                         ; all output rows drawn?
   cmp out_h
   bne @emit
   lda oy+1
   cmp out_h+1
   bne @emit
   lda #PNG_OK                    ; the picture is finished
   jmp png_return
@emitted:
   ; swap the rows: this one is "above" the next
   ldx row_cur
   ldy row_cur+1
   lda row_prev
   sta row_cur
   lda row_prev+1
   sta row_cur+1
   stx row_prev
   sty row_prev+1
   inc sy
   bne :+
   inc sy+1
:
   ; key waiting, or mouse button down? Then stop.
   stz RAM_BANK
   jsr KBDBUF_PEEK
   txa
   bne @abort
   ldx #mouse_x
   jsr MOUSE_GET
   and #$03                       ; left or right button
   bne @abort
   jmp row_begin
@abort:
   lda #PNG_ABORT
   jmp png_return

;------------------------------------------------------------------
; emit_row - draw output row oy from the source row in row_cur
;------------------------------------------------------------------
emit_row:
   ; the panel row: background, with the picture's pixels in the
   ; middle
   ldx #PV_W-1
   lda #PV_BG
:  sta pv_line,x
   dex
   bpl :-
   stz tmp+3                      ; tmp+3 = ox
@pixel:
   ldx tmp+3
   lda row_cur                    ; f_ptr = the source pixel
   clc
   adc col_lo,x
   sta f_ptr
   lda row_cur+1
   adc col_hi,x
   sta f_ptr+1
   lda col_sh,x
   sta cur_sh
   jsr fetch                      ; pr, pg, pb, pa
   jsr map_colour                 ; A = palette entry
   pha
   lda tmp+3
   clc
   adc x_off
   tax
   pla
   sta pv_line,x
   inc tmp+3
   lda tmp+3
   cmp out_w
   bne @pixel

   ; Write it into the tiles. Panel row y is line y mod 8 of tile
   ; row y/8; the 16 tiles across are 64 bytes apart, starting at
   ; TILE_VRAM + 64 (tile 1) + (y/8)*16*64 + (y mod 8)*8.
   lda oy
   and #7
   asl
   asl
   asl
   ora #64
   sta tmp                        ; tmp/tmp+1 = VRAM address
   lda oy+1                       ; (y/8)*1024: high byte = (y/8)*4
   sta tmp+1
   lda oy
   lsr tmp+1
   ror
   lsr tmp+1
   ror
   lsr tmp+1
   ror                            ; A = y/8 (y < 336)
   asl
   asl
   sta tmp+1
   ldx #0                         ; X = position in pv_line
@tile:
   lda tmp
   sta VERA_addr_low
   lda tmp+1
   sta VERA_addr_high
   lda #$10 | ^TILE_VRAM          ; increment 1
   sta VERA_addr_bank
   ldy #8
:  lda pv_line,x
   sta VERA_data0
   inx
   dey
   bne :-
   lda tmp                        ; next tile: 64 bytes on
   clc
   adc #64
   sta tmp
   bcc :+
   inc tmp+1
:  cpx #PV_W
   bne @tile
   rts

fetch:
   jmp (fetch_vec)

;------------------------------------------------------------------
; The pixel readers: read the pixel at f_ptr into pr, pg, pb (0-255)
; and pa (alpha, 255 = solid). For 16-bit values only the high byte
; (the first one) is used.
;------------------------------------------------------------------
fetch_rgb:                        ; colour types 2 and 6
   lda (f_ptr)
   sta pr
   ldy samp
   lda (f_ptr),y
   sta pg
   tya
   clc
   adc samp
   tay
   lda (f_ptr),y
   sta pb
   lda #$FF
   ldx has_alpha
   beq :+
   tya
   clc
   adc samp
   tay
   lda (f_ptr),y
:  sta pa
   rts

fetch_grey:                       ; colour types 0 and 4, 8/16 bits
   lda (f_ptr)
   sta pr
   sta pg
   sta pb
   lda #$FF
   ldx has_alpha
   beq :+
   ldy samp
   lda (f_ptr),y
:  sta pa
   rts

fetch_grey_low:                   ; colour type 0, 1/2/4 bits
   jsr get_low
   clc
   adc exp_off
   tax
   lda exp_tab,x
   sta pr
   sta pg
   sta pb
   lda #$FF
   sta pa
   rts

fetch_idx8:                       ; colour type 3, 8 bits
   lda (f_ptr)
   bra fetch_plte
fetch_idx_low:                    ; colour type 3, 1/2/4 bits
   jsr get_low
fetch_plte:
   tax
   lda #MAP_BANK
   sta RAM_BANK
   lda PLTE_R,x
   sta pr
   lda PLTE_G,x
   sta pg
   lda PLTE_B,x
   sta pb
   lda PLTE_A,x
   sta pa
   rts

; get_low - A = the 1, 2 or 4 bit value at f_ptr, shift cur_sh
get_low:
   lda (f_ptr)
   ldx cur_sh
   beq :+
@shift:
   lsr
   dex
   bne @shift
:  and low_mask
   rts

;------------------------------------------------------------------
; map_colour - A = the palette entry to use for pr, pg, pb, pa
; (see COLOURS at the top of this file)
;------------------------------------------------------------------
map_colour:
   lda pa
   bmi :+                         ; alpha >= 128: solid
   lda #PV_BG                     ; mostly see-through: background
   rts
:  lda pr                         ; cut to 4 bits each
   lsr
   lsr
   lsr
   lsr
   sta red4
   lda pg
   lsr
   lsr
   lsr
   lsr
   sta green4
   lda pb
   lsr
   lsr
   lsr
   lsr
   sta blue4
   ; look up CMAP + r*256 + g*16 + b
   lda #MAP_BANK
   sta RAM_BANK
   lda red4
   ora #>CMAP
   sta m_ptr+1
   lda pg
   and #$F0
   ora blue4
   sta m_ptr
   lda (m_ptr)
   beq @new                       ; 0: not seen yet
   rts

@new:
   ldx pv_next
   cpx #PV_END_COL
   bcs @closest                   ; no entries left
   inc pv_next
   lda red4
   sta USED_R,x
   lda green4
   sta USED_G,x
   lda blue4
   sta USED_B,x
   ; palette entry X at VRAM $1FA00 + X*2: $GB, then $0R
   txa
   asl
   sta VERA_addr_low
   lda #>VRAM_palette
   sta VERA_addr_high
   lda #$10 | ^VRAM_palette
   sta VERA_addr_bank
   lda m_ptr                      ; (that is G*16 + B)
   sta VERA_data0
   lda red4
   sta VERA_data0
   txa
   sta (m_ptr)                    ; remember it
   rts

@closest:
   ; Find the entry given out whose colour is closest: the
   ; smallest (dr*dr + dg*dg + db*db).
   lda #$FF
   sta best_d
   sta best_d+1
   ldx #PV_FIRST_COL
@try:
   lda USED_R,x
   sec
   sbc red4
   bcs :+
   eor #$FF
   inc a
:  tay
   lda squares,y
   sta dist_t
   stz dist_t+1
   lda USED_G,x
   sec
   sbc green4
   bcs :+
   eor #$FF
   inc a
:  tay
   lda squares,y
   clc
   adc dist_t
   sta dist_t
   bcc :+
   inc dist_t+1
:  lda USED_B,x
   sec
   sbc blue4
   bcs :+
   eor #$FF
   inc a
:  tay
   lda squares,y
   clc
   adc dist_t
   sta dist_t
   bcc :+
   inc dist_t+1
:  lda dist_t                     ; closer than the best so far?
   cmp best_d
   lda dist_t+1
   sbc best_d+1
   bcs :+
   lda dist_t
   sta best_d
   lda dist_t+1
   sta best_d+1
   stx best
:  inx
   cpx #PV_END_COL
   bne @try
   lda best
   sta (m_ptr)                    ; remember it for next time
   rts

squares:
   .byte 0, 1, 4, 9, 16, 25, 36, 49, 64, 81, 100, 121, 144, 169, 196, 225

;==================================================================
; Inflate (deflate decompression)
;==================================================================

;------------------------------------------------------------------
; inflate - decompress the zlib stream in the IDAT chunks, passing
; every byte to out_byte. Returns at the end of the last block
; (normally row_done finishes first and never returns).
;------------------------------------------------------------------
inflate:
   ; zlib header: CMF (method 8 = deflate), FLG (no preset dictionary)
   jsr get_zbyte
   and #$0F
   cmp #8
   bne @bad
   jsr get_zbyte
   and #$20
   bne @bad
   stz bitbuf                     ; no bits yet
@block:
   jsr getbit                     ; 1 = the last block
   lda #0
   rol
   sta z_last
   ldx #2                         ; block type
   jsr getbits
   lda val
   beq @stored
   cmp #1
   beq @fixed
   cmp #2
   beq @dynamic
@bad:
   lda #PNG_ERR_DATA
   jmp png_return

@stored:
   ; not compressed: skip to the next whole byte, then LEN, NLEN
   ; (LEN with its bits flipped) and LEN bytes
   stz bitbuf
   jsr get_zbyte
   sta mlen
   jsr get_zbyte
   sta mlen+1
   jsr get_zbyte
   jsr get_zbyte
@copy:
   lda mlen
   ora mlen+1
   beq @next
   jsr get_zbyte
   jsr lit_out
   lda mlen
   bne :+
   dec mlen+1
:  dec mlen
   bra @copy

@fixed:
   jsr build_fixed
   bra @codes
@dynamic:
   jsr build_dynamic
@codes:
   jsr inflate_codes
@next:
   lda z_last
   beq @block
   jmp flush                      ; the last few bytes

;------------------------------------------------------------------
; getbit - the next bit of compressed data, in C
;
; bitbuf holds the bits of the current byte that haven't been used,
; with a 1 bit above them as a marker: shifting right gives the next
; bit, and when only the marker is left (bitbuf becomes 0 after the
; shift) it's time for a new byte. The new byte is stored shifted
; right by 1 with the marker put in at the top, and its bit 0 is
; the bit returned. Preserves X and Y.
;------------------------------------------------------------------
getbit:
   lsr bitbuf
   beq refill_bit
   rts
refill_bit:
   jsr get_zbyte
   sec
   ror
   sta bitbuf
   rts

;------------------------------------------------------------------
; getbits - val = the next X bits (first bit = lowest), X = 0-13
;------------------------------------------------------------------
getbits:
   stz val
   stz val+1
   cpx #0
   beq @done
   lda #1
   sta gmask
   stz gmask+1
@bit:
   lsr bitbuf
   bne :+
   jsr refill_bit
:  bcc :+
   lda val
   ora gmask
   sta val
   lda val+1
   ora gmask+1
   sta val+1
:  asl gmask
   rol gmask+1
   dex
   bne @bit
@done:
   rts

;------------------------------------------------------------------
; lit_out - a decompressed byte in A: store it in the window. The
; filters are undone later, 256 bytes at a time (see flush).
;------------------------------------------------------------------
lit_out:
   ldx win_bank
   stx RAM_BANK
   sta (win_ptr)
   inc win_ptr
   bne :+
   jsr win_page
:  inc pending
   beq :+
   rts
:  inc pending+1                  ; 256 waiting: deal with them
   jmp flush

; win_page - win_ptr has gone past the end of a page: the next page,
; or after the end of the bank the start of the next (after the
; 4th bank back to the 1st)
win_page:
   inc win_ptr+1
   lda win_ptr+1
   cmp #>(RAM_WIN+RAM_WIN_SIZE)
   bne @done
   lda #>RAM_WIN
   sta win_ptr+1
   inc win_bank
   lda win_bank
   cmp #WIN_BANK+4
   bne @done
   lda #WIN_BANK
   sta win_bank
@done:
   rts

;------------------------------------------------------------------
; inflate_codes - decode one Huffman-coded block
;------------------------------------------------------------------
inflate_codes:
@loop:
   jsr decode_lit
   lda sym+1
   bne @not_lit
   lda sym                        ; 0-255: a literal byte
   jsr lit_out
   bra @loop
@not_lit:
   lda sym                        ; 256: end of block
   bne :+
   rts
:  ; 257-285: a match. Its length is a base plus extra bits.
   sec
   sbc #1                         ; sym - 257 (sym+1 is 1)
   cmp #29
   bcs @bad
   tay
   lda len_base_lo,y
   sta mlen
   lda len_base_hi,y
   sta mlen+1
   ldx len_extra,y
   jsr getbits
   lda mlen
   clc
   adc val
   sta mlen
   lda mlen+1
   adc val+1
   sta mlen+1
   ; then its distance
   jsr decode_dst
   lda sym
   cmp #30
   bcs @bad
   tay
   lda dist_base_lo,y
   sta mdist
   lda dist_base_hi,y
   sta mdist+1
   ldx dist_extra,y
   jsr getbits
   lda mdist
   clc
   adc val
   sta mdist
   lda mdist+1
   adc val+1
   sta mdist+1
   jsr copy_match
   bra @loop
@bad:
   lda #PNG_ERR_DATA
   jmp png_return

len_base_lo:
   .byte <3, <4, <5, <6, <7, <8, <9, <10, <11, <13, <15, <17, <19, <23
   .byte <27, <31, <35, <43, <51, <59, <67, <83, <99, <115, <131, <163
   .byte <195, <227, <258
len_base_hi:
   .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
   .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
   .byte 0, 0, >258
len_extra:
   .byte 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3
   .byte 4, 4, 4, 4, 5, 5, 5, 5, 0
dist_base_lo:
   .byte <1, <2, <3, <4, <5, <7, <9, <13, <17, <25, <33, <49, <65, <97
   .byte <129, <193, <257, <385, <513, <769, <1025, <1537, <2049, <3073
   .byte <4097, <6145, <8193, <12289, <16385, <24577
dist_base_hi:
   .byte >1, >2, >3, >4, >5, >7, >9, >13, >17, >25, >33, >49, >65, >97
   .byte >129, >193, >257, >385, >513, >769, >1025, >1537, >2049, >3073
   .byte >4097, >6145, >8193, >12289, >16385, >24577
dist_extra:
   .byte 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8
   .byte 9, 9, 10, 10, 11, 11, 12, 12, 13, 13

;------------------------------------------------------------------
; copy_match - copy mlen bytes from mdist bytes back in the window
;------------------------------------------------------------------
copy_match:
   ; Window position of the next free byte, 0-32767:
   ;   (win_bank - WIN_BANK) * 8192 + (win_ptr - $A000)
   ; minus the distance, wrapped round to 0-32767. Its top 2 bits
   ; are the bank, the rest the address in the bank.
   lda win_bank
   sec
   sbc #WIN_BANK
   asl
   asl
   asl
   asl
   asl
   sta tmp                        ; bank * 32 (high byte units)
   lda win_ptr+1
   sec
   sbc #>RAM_WIN
   ora tmp
   sta tmp                        ; position high byte (0-127)
   lda win_ptr
   sec
   sbc mdist
   sta cp_ptr
   lda tmp
   sbc mdist+1
   and #$7F                       ; wrap round
   pha
   and #$1F
   ora #>RAM_WIN
   sta cp_ptr+1
   pla
   lsr
   lsr
   lsr
   lsr
   lsr
   clc
   adc #WIN_BANK
   sta cp_bank

   lda pending                    ; these bytes will need filtering
   clc
   adc mlen
   sta pending
   lda pending+1
   adc mlen+1
   sta pending+1

@run:
   ; Copy in runs that stay inside one bank at both ends (at most
   ; 256 bytes, so Y can count them). If the source is close
   ; behind, the copy reads bytes it has only just written - that
   ; is how deflate repeats short patterns.
   lda mlen
   sta run_n
   lda mlen+1
   sta run_n+1
   jsr cap_256
   lda cp_ptr
   ldx cp_ptr+1
   jsr cap_bank_end
   lda win_ptr
   ldx win_ptr+1
   jsr cap_bank_end
   ldy #0
   lda cp_bank
   cmp win_bank
   bne @two_banks
   sta RAM_BANK                   ; both in the same bank
:  lda (cp_ptr),y
   sta (win_ptr),y
   iny
   cpy run_n
   bne :-
   bra @moved
@two_banks:                       ; switch banks for every byte
:  ldx cp_bank
   stx RAM_BANK
   lda (cp_ptr),y
   ldx win_bank
   stx RAM_BANK
   sta (win_ptr),y
   iny
   cpy run_n
   bne :-
@moved:
   ; move both on by run_n
   lda cp_ptr
   clc
   adc run_n
   sta cp_ptr
   lda cp_ptr+1
   adc run_n+1
   cmp #>(RAM_WIN+RAM_WIN_SIZE)
   bcc :+
   sbc #>RAM_WIN_SIZE             ; (carry is set)
   inc cp_bank
   ldx cp_bank
   cpx #WIN_BANK+4
   bne :+
   ldx #WIN_BANK
   stx cp_bank
:  sta cp_ptr+1
   lda win_ptr
   clc
   adc run_n
   sta win_ptr
   lda win_ptr+1
   adc run_n+1
   cmp #>(RAM_WIN+RAM_WIN_SIZE)
   bcc :+
   sbc #>RAM_WIN_SIZE
   inc win_bank
   ldx win_bank
   cpx #WIN_BANK+4
   bne :+
   ldx #WIN_BANK
   stx win_bank
:  sta win_ptr+1
   lda mlen                       ; mlen -= run_n
   sec
   sbc run_n
   sta mlen
   lda mlen+1
   sbc run_n+1
   sta mlen+1
   ora mlen
   beq :+
   jmp @run
:  lda pending+1                  ; 256 or more waiting?
   beq :+
   jmp flush
:  rts

;------------------------------------------------------------------
; Huffman tables
;
; construct is told which table to build by 6 pointers in zero page
; (h_cl, h_ch, h_ol, h_oh, h_sl, h_sh), copied from tables_info by
; use_table: X = 0 literal/length, 12 distance, 24 code length.
; Decoding uses a separate copy of the decoder for each table (made
; by the DECODER macro) so it can address the tables directly,
; which is quicker.
;------------------------------------------------------------------
use_table:
   ldy #0
:  lda tables_info,x
   sta h_cl,y
   inx
   iny
   cpy #12
   bne :-
   rts

tables_info:
   .word lit_cl, lit_ch, lit_ol, lit_oh, lit_sl, lit_sh
   .word dst_cl, dst_ch, dst_ol, dst_oh, dst_sl, dst_sh
   .word cl_cl, cl_ch, cl_ol, cl_oh, cl_sl, cl_sh

;------------------------------------------------------------------
; decode_lit / decode_dst / decode_cl - read one Huffman code
; Out: sym = the symbol (16-bit)
;
; Canonical Huffman codes of the same length are numbered one after
; another, and all the codes of one length come before (are smaller
; than) the longer ones. Reading a bit at a time, "diff" is how far
; the code read so far is past the first code of this length. If it
; is less than the number of codes of this length (count), the
; symbol is number offs + diff in the sorted list, where offs is
; how many symbols have shorter codes. If not, the code is longer:
; take count off diff, then diff = diff * 2 + the next bit.
;------------------------------------------------------------------
.macro DECODER t_cl, t_ch, t_ol, t_oh, t_sl, t_sh
   .local bit, have, found, big
   stz diff
   stz diff+1
   ldy #1                         ; Y = code length so far
bit:
   lsr bitbuf                     ; next bit into C (see getbit)
   bne have
   jsr refill_bit
have:
   rol diff                       ; diff = diff * 2 + bit
   rol diff+1
   lda diff                       ; diff - count: no borrow means
   sec                            ;   diff >= count, so the code is
   sbc t_cl,y                     ;   longer
   tax
   lda diff+1
   sbc t_ch,y
   bcc found
   sta diff+1                     ; diff -= count
   stx diff
   iny
   cpy #16
   bne bit
   lda #PNG_ERR_DATA              ; no such code
   jmp png_return
found:
   lda t_ol,y                     ; X = symbol number offs + diff
   clc
   adc diff
   tax
   lda t_oh,y
   adc diff+1
   bne big
   lda t_sl,x                     ; (less than 256: the quick way)
   sta sym
   lda t_sh,x
   sta sym+1
   rts
big:                              ; 256 or more (literal/length only)
   sta s_ptr+1
   stx s_ptr
   lda s_ptr
   clc
   adc #<t_sl
   sta l_ptr
   lda s_ptr+1
   adc #>t_sl
   sta l_ptr+1
   lda (l_ptr)
   sta sym
   lda s_ptr
   clc
   adc #<t_sh
   sta l_ptr
   lda s_ptr+1
   adc #>t_sh
   sta l_ptr+1
   lda (l_ptr)
   sta sym+1
   rts
.endmacro

decode_lit:
   DECODER lit_cl, lit_ch, lit_ol, lit_oh, lit_sl, lit_sh
decode_dst:
   DECODER dst_cl, dst_ch, dst_ol, dst_oh, dst_sl, dst_sh
decode_cl:
   DECODER cl_cl, cl_ch, cl_ol, cl_oh, cl_sl, cl_sh

;------------------------------------------------------------------
; construct - build table X (see use_table) from the code lengths at
; l_ptr (cn of them, one per symbol, 0 = symbol not used)
;------------------------------------------------------------------
construct:
   jsr use_table
   ; count the codes of each length
   ldy #15
   lda #0
:  sta (h_cl),y
   sta (h_ch),y
   dey
   bpl :-
   lda l_ptr
   sta s_ptr
   lda l_ptr+1
   sta s_ptr+1
   lda cn
   sta symc
   lda cn+1
   sta symc+1
@count:
   lda symc
   ora symc+1
   beq @counted
   lda (s_ptr)
   tay
   lda (h_cl),y
   inc a
   sta (h_cl),y
   bne :+
   lda (h_ch),y
   inc a
   sta (h_ch),y
:  inc s_ptr
   bne :+
   inc s_ptr+1
:  lda symc
   bne :+
   dec symc+1
:  dec symc
   bra @count
@counted:
   ; offs[len] = where the first symbol with that length goes
   stz offs_lo
   stz offs_hi
   stz offs_lo+1
   stz offs_hi+1
   ldy #1
:  lda offs_lo,y
   clc
   adc (h_cl),y
   sta offs_lo+1,y
   lda offs_hi,y
   adc (h_ch),y
   sta offs_hi+1,y
   iny
   cpy #15
   bne :-
   ldy #15                        ; keep a copy for decoding
:  lda offs_lo,y
   sta (h_ol),y
   lda offs_hi,y
   sta (h_oh),y
   dey
   bpl :-
   ; put the symbols in order
   stz symc
   stz symc+1
@sym:
   lda symc
   cmp cn
   bne :+
   lda symc+1
   cmp cn+1
   beq @done
:  lda symc                       ; length of this symbol
   clc
   adc l_ptr
   sta s_ptr
   lda symc+1
   adc l_ptr+1
   sta s_ptr+1
   lda (s_ptr)
   beq @skip                      ; not used
   tax
   lda h_sl                       ; symbols[offs[len]] = symc
   clc
   adc offs_lo,x
   sta s_ptr
   lda h_sl+1
   adc offs_hi,x
   sta s_ptr+1
   lda symc
   sta (s_ptr)
   lda h_sh
   clc
   adc offs_lo,x
   sta s_ptr
   lda h_sh+1
   adc offs_hi,x
   sta s_ptr+1
   lda symc+1
   sta (s_ptr)
   inc offs_lo,x                  ; offs[len] += 1
   bne @skip
   inc offs_hi,x
@skip:
   inc symc
   bne @sym
   inc symc+1
   bra @sym
@done:
   rts

;------------------------------------------------------------------
; build_fixed - the fixed tables of block type 1:
;   literal/length 0-143: 8 bits, 144-255: 9, 256-279: 7, 280-287: 8
;   distance 0-29: 5 bits
;------------------------------------------------------------------
build_fixed:
   ldx #0
:  lda #8
   cpx #144
   bcc :+
   lda #9
:  sta lengths,x
   inx
   bne :--
:  lda #7
   cpx #24
   bcc :+
   lda #8
:  sta lengths+256,x
   inx
   cpx #32
   bne :--
   lda #<lengths
   sta l_ptr
   lda #>lengths
   sta l_ptr+1
   lda #<288
   sta cn
   lda #>288
   sta cn+1
   ldx #0
   jsr construct
   ldx #29
   lda #5
:  sta lengths,x
   dex
   bpl :-
   lda #30
   sta cn
   stz cn+1
   ldx #12
   jmp construct

;------------------------------------------------------------------
; build_dynamic - read the tables of block type 2.
; The block starts with HLIT (5 bits) + 257 literal/length code
; lengths, HDIST (5 bits) + 1 distance code lengths and HCLEN
; (4 bits) + 4 "code length code" lengths (3 bits each, in a
; strange order). The code length code then decodes the other
; lengths, which can be repeated: 16 = repeat the last length 3-6
; times, 17 = 3-10 zeros, 18 = 11-138 zeros.
;------------------------------------------------------------------
build_dynamic:
   ldx #5
   jsr getbits
   lda val
   clc
   adc #<257
   sta nlen
   lda #>257
   adc #0
   sta nlen+1
   ldx #5
   jsr getbits
   lda val
   inc a
   sta ndist
   ldx #4
   jsr getbits
   lda val
   clc
   adc #4
   sta rep                        ; rep = number of HCLEN lengths
   ldx #18
:  stz lengths,x
   dex
   bpl :-
   stz tmp+3
:  ldx #3
   jsr getbits
   ldx tmp+3
   ldy cl_order,x
   lda val
   sta lengths,y
   inc tmp+3
   lda tmp+3
   cmp rep
   bne :-
   lda #<lengths
   sta l_ptr
   lda #>lengths
   sta l_ptr+1
   lda #19
   sta cn
   stz cn+1
   ldx #24
   jsr construct

   ; now read nlen + ndist lengths
   lda nlen
   clc
   adc ndist
   sta ntotal
   lda nlen+1
   adc #0
   sta ntotal+1
   stz li
   stz li+1
@next:
   lda li
   cmp ntotal
   bne :+
   lda li+1
   cmp ntotal+1
   bne :+
   jmp @read
:  jsr decode_cl
   lda sym
   cmp #16
   bcs @repeat
   jsr @put                       ; a length 0-15
   bra @next
@repeat:
   bne @zeros
   ; 16: repeat the last length 3 + (2 bits) times
   lda li
   ora li+1
   beq @bad                       ; there is no last length
   lda li                         ; repv = lengths[li - 1]
   sec
   sbc #1
   sta s_ptr
   lda li+1
   sbc #0
   sta s_ptr+1
   lda s_ptr
   clc
   adc #<lengths
   sta s_ptr
   lda s_ptr+1
   adc #>lengths
   sta s_ptr+1
   lda (s_ptr)
   sta repv
   ldx #2
   lda #3
   bra @run
@zeros:
   stz repv
   cmp #17
   bne :+
   ldx #3                         ; 17: 3 + (3 bits) zeros
   lda #3
   bra @run
:  ldx #7                         ; 18: 11 + (7 bits) zeros
   lda #11
@run:
   pha
   jsr getbits
   pla
   clc
   adc val
   sta rep
:  lda li                         ; too many?
   cmp ntotal
   bne :+
   lda li+1
   cmp ntotal+1
   beq @bad
:  lda repv
   jsr @put
   dec rep
   bne :--
   jmp @next

@put:                             ; lengths[li] = A, li += 1
   pha
   lda li
   clc
   adc #<lengths
   sta s_ptr
   lda li+1
   adc #>lengths
   sta s_ptr+1
   pla
   sta (s_ptr)
   inc li
   bne :+
   inc li+1
:  rts

@bad:
   lda #PNG_ERR_DATA
   jmp png_return

@read:
   ; literal/length table from the first nlen lengths ...
   lda #<lengths
   sta l_ptr
   lda #>lengths
   sta l_ptr+1
   lda nlen
   sta cn
   lda nlen+1
   sta cn+1
   ldx #0
   jsr construct
   ; ... distance table from the rest
   lda #<lengths
   clc
   adc nlen
   sta l_ptr
   lda #>lengths
   adc nlen+1
   sta l_ptr+1
   lda ndist
   sta cn
   stz cn+1
   ldx #12
   jmp construct

cl_order:
   .byte 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
