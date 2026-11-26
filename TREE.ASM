;******************************************************************
; TREE.ASM - the folder tree, and record storage in banked RAM
;
; HOW THE TREE IS STORED
; The tree is kept as a flat list of nodes in the order they appear
; on screen. Each node remembers its depth (root = 0). For example:
;
;   node  depth  shown as
;    0     0     [-] SD Card
;    1     1      [-] GAMES
;    2     2       [+] ARCADE
;    3     2       [+] PUZZLE
;    4     1      [+] TOOLS
;
; - A node's parent is the nearest node above it that is one level
;   shallower (ARCADE's parent is GAMES).
; - Expanding a node inserts its sub-folders straight after it, one
;   level deeper; the nodes below move down to make room.
; - Collapsing a node removes the deeper nodes that follow it (its
;   whole subtree); the nodes below move up to close the gap.
;
; Nodes are 64 byte records in banked RAM (see the record layout at
; the top of GUIMENU.ASM). Node N lives in bank TREE_BANK + N/128,
; at $A000 + (N mod 128) * 64.
;******************************************************************

;------------------------------------------------------------------
; Record pointers
;   tree_ptr - tree node        (banks 1-2)
;   file_ptr - file             (banks 3-4)
;   tdir_ptr - sub-folder read  (bank 5)
;   sort_ptr - a record in the list being sorted (bank sort_bank,
;              or the one after it for records 128+)
; In:  A = record number
; Out: RAM_BANK switched to the record's bank, ptr -> the record.
;      X is changed.
; Callers must set RAM_BANK back to 0 before calling the KERNAL.
;------------------------------------------------------------------
tree_ptr:
   pha
   asl                            ; bit 7 of the node number -> carry
   lda #TREE_BANK
   adc #0                         ; nodes 128+ are in the next bank
   sta RAM_BANK
   pla
   bra rec_addr

file_ptr:
   pha
   asl                            ; bit 7 of the file number -> carry
   lda #FILE_BANK
   adc #0                         ; files 128+ are in the next bank
   sta RAM_BANK
   pla
   bra rec_addr

sort_ptr:
   pha
   asl                            ; bit 7 of the record number
   lda sort_bank
   adc #0                         ; records 128+ are in the next bank
   sta RAM_BANK
   pla
   bra rec_addr

tdir_ptr:
   pha
   lda #TDIR_BANK
   sta RAM_BANK
   pla
   ; fall through into rec_addr

;------------------------------------------------------------------
; rec_addr - ptr = $A000 + (A mod 128) * 64
; Multiplying by 64 is the same as: high byte = A / 4, low byte =
; (A mod 4) * 64, which is what this does (with a little table for
; the low byte). Doesn't change RAM_BANK.
;------------------------------------------------------------------
rec_addr:
   and #$7F                       ; record number within the bank
   pha
   lsr
   lsr                            ; A / 4
   clc
   adc #>RAM_WIN                  ; + $A0
   sta ptr+1
   pla
   and #$03                       ; A mod 4
   tax
   lda rec_lo,x                   ; * 64
   sta ptr
   rts
rec_lo: .byte $00, $40, $80, $C0

;------------------------------------------------------------------
; load_rec  - copy the 64 byte record at ptr into recbuf
; store_rec - copy recbuf into the record at ptr
; Both switch RAM_BANK back to 0 when done. Y is changed.
;------------------------------------------------------------------
load_rec:
   ldy #63
:  lda (ptr),y
   sta recbuf,y
   dey
   bpl :-                         ; 63 down to 0
   stz RAM_BANK
   rts

store_rec:
   ldy #63
:  lda recbuf,y
   sta (ptr),y
   dey
   bpl :-
   stz RAM_BANK
   rts

;------------------------------------------------------------------
; move_tree_rec - copy tree node number tmp to node number tmp+1
; (via recbuf, since the two may be in different banks)
;------------------------------------------------------------------
move_tree_rec:
   lda tmp
   jsr tree_ptr
   jsr load_rec
   lda tmp+1
   jsr tree_ptr
   jmp store_rec

;------------------------------------------------------------------
; tree_init - start with a tree holding only the root folder
;------------------------------------------------------------------
tree_init:
   ; build the root's record in recbuf: depth 0, no flags, name
   ldx #63
:  stz recbuf,x                   ; clear the whole record
   dex
   bpl :-
   ldx #0
:  lda str_root,x                 ; copy the name, including its 0
   sta recbuf+REC_NAME,x
   beq :+
   inx
   bra :-
:  lda #0                         ; store it as node 0
   jsr tree_ptr
   jsr store_rec
   lda #1
   sta tree_count
   stz tree_sel
   rts

; Name shown for the root. Written as ASCII bytes because names are
; printed with put_ascii (the assembler would store "..." as PETSCII).
str_root: .byte $53, $44, $20, $43, $61, $72, $64, 0   ; "SD Card"

;------------------------------------------------------------------
; node_depth - In: A = node.  Out: A = its depth.  RAM_BANK = 0.
;------------------------------------------------------------------
node_depth:
   jsr tree_ptr
   lda (ptr)                      ; byte 0 of the record (REC_DEPTH)
   stz RAM_BANK
   rts

;------------------------------------------------------------------
; insert_children - expand a node
; In: A = node. It must be the folder read_dir just read, because
;     its sub-folders are taken from TDIR_BANK / tdir_order.
;
; 1. Move every node after it down by the number of sub-folders.
; 2. Copy the sub-folders (already sorted) into the gap, one level
;    deeper than the node.
; 3. Mark the node as expanded (and "no sub-folders" if it had none).
;------------------------------------------------------------------
insert_children:
   sta tmp+3                      ; tmp+3 = node
   jsr node_depth
   inc a
   sta tmp+2                      ; tmp+2 = depth of the children
   stz ins_count
   cmp #MAX_DEPTH+1
   bcs @flags                     ; too deep: show no children

   ; how many to insert: all of them, unless the tree would overflow
   lda #MAX_TREE
   sec
   sbc tree_count                 ; free space in the tree
   cmp tdir_count
   bcc :+
   lda tdir_count
:  sta ins_count                  ; ins_count = number to insert
   beq @flags                     ; none

   ; Step 1: move nodes node+1 .. tree_count-1 down by ins_count.
   ; Work from the last node upwards so nothing is overwritten
   ; before it has been moved.
   lda tree_count
   sta ins_src                    ; ins_src = one past the node to move
@shift:
   lda ins_src
   dec a
   cmp tmp+3
   beq @copy                      ; reached the node itself: done
   sta ins_src
   sta tmp                        ; from
   clc
   adc ins_count
   sta tmp+1                      ; to = from + ins_count
   jsr move_tree_rec
   bra @shift

@copy:
   ; Step 2: copy the sub-folders into the gap, in sorted order.
   stz ins_src                    ; ins_src = position in tdir_order
@next:
   ldx ins_src
   lda tdir_order,x               ; record number of the sub-folder
   jsr tdir_ptr
   jsr load_rec                   ; recbuf = its record (name)
   lda tmp+2
   sta recbuf+REC_DEPTH           ; set its depth
   stz recbuf+REC_FLAGS           ; not expanded yet
   lda tmp+3
   sec                            ; destination = node + 1 + position
   adc ins_src                    ; (SEC makes ADC add the extra 1)
   jsr tree_ptr
   jsr store_rec
   inc ins_src
   lda ins_src
   cmp ins_count
   bne @next

   lda tree_count                 ; the tree has grown
   clc
   adc ins_count
   sta tree_count

@flags:
   ; Step 3: mark the node expanded (and empty, if it is)
   lda tmp+3
   jsr tree_ptr
   ldy #REC_FLAGS
   lda #FLAG_EXPANDED
   ldx ins_count
   bne :+
   ora #FLAG_NOKIDS
:  sta (ptr),y
   stz RAM_BANK
   rts

.pushseg
.segment "BSS"
ins_count: .res 1                 ; nodes being inserted / removed
ins_src:   .res 1                 ; loop counter
.popseg

;------------------------------------------------------------------
; collapse_node - collapse a node
; In: A = node
;
; 1. Find the end of its subtree: the first node after it that is
;    not deeper than it.
; 2. Move the nodes from there to the end of the tree up, over the
;    subtree.
; 3. Clear the node's expanded flag.
; 4. Fix up tree_sel. If the open folder was inside the removed
;    subtree, the collapsed node becomes the open folder.
;------------------------------------------------------------------
collapse_node:
   sta tmp+3                      ; tmp+3 = node
   jsr node_depth
   sta tmp+2                      ; tmp+2 = its depth

   ; Step 1: find the end of the subtree
   ldx tmp+3
@find:
   inx
   cpx tree_count
   beq @found                     ; reached the end of the tree
   phx
   txa
   jsr node_depth
   plx
   cmp tmp+2
   beq @found                     ; same depth: a sibling
   bcs @find                      ; deeper: still in the subtree
@found:                           ; (shallower also ends it)
   stx ins_src                    ; ins_src = first node to keep
   txa
   clc                            ; removed = end - node - 1
   sbc tmp+3                      ; (SBC with carry clear takes 1 more)
   sta ins_count

   ; Step 2: move nodes ins_src .. tree_count-1 up to node+1 ..
   lda tmp+3
   inc a
   sta tmp+1                      ; tmp+1 = destination
@move:
   lda ins_src
   cmp tree_count
   beq @moved
   sta tmp                        ; tmp = source
   jsr move_tree_rec
   inc ins_src
   inc tmp+1
   bra @move
@moved:
   lda tree_count                 ; the tree has shrunk
   sec
   sbc ins_count
   sta tree_count

   ; Step 3: clear the node's flags (not expanded)
   lda tmp+3
   jsr tree_ptr
   ldy #REC_FLAGS
   lda #0
   sta (ptr),y
   stz RAM_BANK

   ; Step 4: fix up the open folder (tree_sel)
   lda tree_sel
   cmp tmp+3
   beq @redraw                    ; it is the collapsed node: fine
   bcc @redraw                    ; it is above: unchanged
   sec
   sbc tmp+3                      ; how far below the collapsed node
   cmp ins_count
   beq :+
   bcs @below                     ; below the removed subtree
:  ; It was inside the removed subtree: open the collapsed node
   ; instead (without expanding it again).
   lda tmp+3
   sta tree_sel
   jsr goto_node
   jsr read_dir
   lda #$FF
   sta file_sel
   sta last_click_idx
   stz file_scroll
   jsr draw_files
   jsr draw_status
   bra @redraw
@below:
   lda tree_sel                   ; it moved up with the other nodes
   sec
   sbc ins_count
   sta tree_sel
@redraw:
   ; the tree is shorter, so make sure the scroll position is valid
   jsr scroll_tree_clamp
   jsr ensure_tree_visible
   jmp draw_tree

; scroll_tree_clamp - pull tree_scroll back in range after the tree
; shrank (calc_scroll with a movement of 0 just clamps).
scroll_tree_clamp:
   ldx #BAR_TREE
   jsr sb_load
   lda #0
   jsr calc_scroll
   lda sb_new
   sta tree_scroll
   rts

;------------------------------------------------------------------
; goto_node - make a tree node DOS's current directory
; In: A = node
;
; 1. Walk up from the node to the root, recording the node at each
;    depth in "chain" (chain[1] = top level folder ... chain[depth]
;    = the node itself).
; 2. Send DOS "CD:/" to go to the root folder.
; 3. Send "CD:name" for each folder in the chain, top level first.
;    At the same time build the path ("/GAMES/ARCADE") in pathbuf
;    for the status line.
;------------------------------------------------------------------
goto_node:
   sta tmp+3                      ; tmp+3 = node
   jsr node_depth
   sta tmp+2                      ; tmp+2 = depth of the node
   tax                            ; X = depth we are at
   lda tmp+3
   sta tmp+1                      ; tmp+1 = node we are at

   ; Step 1: walk up to the root
@up:
   cpx #0
   beq @built                     ; reached the root
   lda tmp+1
   sta chain,x                    ; remember the node at this depth
   dex
   stx tmp                        ; tmp = the parent's depth
@scan:                            ; the parent is the nearest node
   dec tmp+1                      ;   above with that depth
   lda tmp+1
   jsr node_depth
   cmp tmp
   bne @scan
   ldx tmp
   bra @up

@built:
   ; Step 2: "CD:/" - back to the root
   ldx #0
:  lda cmd_root,x
   sta cmdbuf,x
   inx
   cpx #cmd_root_end-cmd_root
   bne :-
   stx cmdlen
   jsr dos_command

   lda #'/'                       ; path starts as "/"
   sta pathbuf
   stz pathbuf+1
   ldx #1
   stx path_len

   ; Step 3: down one folder at a time
   lda #1
   sta tmp                        ; tmp = depth being entered
@down:
   lda tmp
   cmp tmp+2
   beq :+
   bcs @done                      ; past the node's depth: finished
:  ldx tmp
   lda chain,x                    ; node at this depth
   jsr tree_ptr
   jsr load_rec                   ; recbuf = its record

   ; build "CD:" + name in cmdbuf. The bytes are written as numbers
   ; because the assembler would turn 'C' into a PETSCII capital.
   lda #$43                       ; C
   sta cmdbuf
   lda #$44                       ; D
   sta cmdbuf+1
   lda #$3A                       ; :
   sta cmdbuf+2
   ldx #3
   ldy #REC_NAME
:  lda recbuf,y                   ; append the name
   beq :+
   sta cmdbuf,x
   inx
   iny
   bra :-
:  stx cmdlen
   jsr dos_command

   ; add "/name" to the path (no "/" needed straight after the root)
   ldx path_len
   cpx #1
   beq :+
   lda #'/'
   jsr path_add
:  ldy #REC_NAME
:  lda recbuf,y
   beq :+
   jsr path_add
   iny
   bra :-
:
   inc tmp                        ; next depth
   bra @down
@done:
   rts

; path_add - append character A to pathbuf (ignored once it is full)
path_add:
   ldx path_len
   cpx #250
   bcs :+
   sta pathbuf,x
   stz pathbuf+1,x                ; keep it 0-terminated
   inc path_len
:  rts

.pushseg
.segment "BSS"
path_len: .res 1                  ; length of the string in pathbuf
.popseg

cmd_root:     .byte $43, $44, $3A, $2F     ; "CD:/"
cmd_root_end:

;------------------------------------------------------------------
; sort_records - sort a list of records alphabetically (ignoring
; upper/lower case), in groups: programs, then pictures, then text
; files, then everything else (see compare_names).
;
; In: sort_bank = the (first) bank the records are in
;     optr      = the "order" array to fill in (file_order or
;                 tdir_order)
;     X         = number of records
;
; The records themselves don't move (each is 64 bytes, so moving
; them would be slow). Instead the order array is filled with record
; numbers 0,1,2,... and those single bytes are sorted.
;
; This is an "insertion sort": take each entry in turn (the "key")
; and slide it backwards past every earlier entry whose name comes
; after it. Simple, and quick enough for 255 names.
;
; The records can be in two banks, and only one bank can be seen at
; a time, so the key's record is copied into recbuf (normal RAM)
; and each earlier record is compared with that copy.
;------------------------------------------------------------------
sort_records:
   stx sort_n
   ; order[i] = i
   ldy #0
:  cpy sort_n
   beq :+
   tya
   sta (optr),y
   iny
   bra :-
:
   lda #1
   sta sort_i                     ; sort_i = entry being placed
@outer:
   lda sort_i
   cmp sort_n
   bcs @done                      ; all entries placed
   tay
   lda (optr),y
   sta sort_key                   ; key = order[i]
   sty sort_j                     ; j = i
   jsr sort_ptr                   ; copy the key's record into recbuf
   jsr load_rec                   ;   (load_rec sets RAM_BANK to 0)
@inner:
   ldy sort_j
   beq @place                     ; reached the front of the list
   dey
   lda (optr),y                   ; order[j-1]
   jsr sort_ptr                   ; ptr -> its record, bank switched
   jsr compare_names              ; C=1 if it sorts after the key
   stz RAM_BANK
   bcc @place                     ; order[j-1] comes first: stop here
   ldy sort_j                     ; otherwise move order[j-1] up one
   dey
   lda (optr),y
   iny
   sta (optr),y                   ; order[j] = order[j-1]
   dec sort_j
   bra @inner
@place:
   ldy sort_j
   lda sort_key
   sta (optr),y                   ; order[j] = key
   inc sort_i
   bra @outer
@done:
   rts

;------------------------------------------------------------------
; compare_names - decide which comes first: the record at ptr, or
; the key record copied into recbuf
; Out: C = 1 if the record at ptr comes after the key, else C = 0
; (RAM_BANK must already be set to ptr's bank.)
;
; The file list is in groups, so the files people use are near the
; top:
;   0  programs  (FLAG_PRG, .PRG)
;   1  pictures  (FLAG_PNG, .PNG)
;   2  text      (FLAG_TXT, .TXT and .MD)
;   3  everything else
; If the two are in different groups, the group decides it;
; otherwise the names are compared. Folder records (sub-folders
; being sorted for the tree) have no flags yet, so they are all in
; group 3 and just sort by name.
;------------------------------------------------------------------
compare_names:
   lda recbuf+REC_FLAGS           ; the key's group
   jsr sort_group
   sta tmp
   ldy #REC_FLAGS                 ; ptr's group
   lda (ptr),y
   jsr sort_group
   cmp tmp                        ; C = 1 if ptr's group >= the key's
   beq @by_name                   ; same group: compare the names
   rts                            ; different: C is the answer

@by_name:
   ldy #REC_NAME
@loop:
   lda recbuf,y
   jsr fold_case
   sta tmp                        ; character from the key
   lda (ptr),y
   jsr fold_case                  ; character from ptr
   cmp tmp                        ; C = 1 if ptr's >= the key's
   bne @diff                      ; different: C is the answer
   cmp #0
   beq @equal                     ; both names ended: equal
   iny
   cpy #64
   bne @loop
@equal:
   clc                            ; equal does not count as "after"
@diff:
   rts

;------------------------------------------------------------------
; sort_group - A = the group (0-3, see compare_names) of a record
; whose flags are in A. A file has at most one of FLAG_PRG
; (bit 0), FLAG_PNG (bit 1) and FLAG_TXT (bit 2) set, so the
; bottom 3 bits pick an entry in sort_groups.
;------------------------------------------------------------------
sort_group:
   and #FLAG_PRG | FLAG_PNG | FLAG_TXT
   tax
   lda sort_groups,x
   rts

.assert FLAG_PRG = 1 && FLAG_PNG = 2 && FLAG_TXT = 4, error, "sort_groups expects these flag bits"
;                  none PRG  PNG  -    TXT  -    -    -
sort_groups: .byte 3,   0,   1,   3,   2,   3,   3,   3

;------------------------------------------------------------------
; fold_case - change an ASCII lower case letter in A to upper case,
; so that "apple" and "APPLE" sort together.
;------------------------------------------------------------------
fold_case:
   cmp #$61                       ; 'a'
   bcc :+
   cmp #$7B                       ; one past 'z'
   bcs :+
   and #$DF                       ; clear bit 5: a-z -> A-Z
:  rts

.pushseg
.segment "BSS"
sort_bank: .res 1                 ; bank holding the records
sort_n:    .res 1                 ; number of records
sort_i:    .res 1                 ; entry being placed
sort_j:    .res 1                 ; where it is being slid to
sort_key:  .res 1                 ; the record number being placed
.popseg
