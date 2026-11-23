# X16 GUI Menu
CC       = cl65
CFLAGS   = -t cx16 -C cx16-asm.cfg -u __EXEHDR__
PROGNAME = GUIMENU
SOURCES  = GUIMENU.ASM SCREEN.ASM TREE.ASM DOS.ASM LAUNCH.ASM INC/x16.inc

# Default target
all: $(PROGNAME).PRG

$(PROGNAME).PRG: $(SOURCES)
	$(CC) $(CFLAGS) -o $(PROGNAME).PRG -l $(PROGNAME).LIST -Ln $(PROGNAME).SYM $(PROGNAME).ASM

# Clean target to wipe out compiled binaries and start fresh
clean:
	rm -f $(PROGNAME).PRG $(PROGNAME).LIST $(PROGNAME).SYM *.o
