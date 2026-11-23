# X16 GUI Menu

This project creates a mouse driven user interface for users to be able to navigate the SDCard filesystem and launch programs, targeting the Commander X16 computer.

The application should run in display the Commander X16 logo in the top left of the screen with the words "Commander X16".

The user interface should consist of a window consisting of three columns:
- A tree view representing the folders on the SDCard.
- A list of files for the currently selected folder.
- A panel for showing an image representing the program that is in the currently selected folder. (for now, don't write any code for this.  We'll do this later)

Files with a .PRG extension are programs and they should be displayed a different colour, the intention being to guide the user to that file.

When a user double-clicks on a PRG file, is application should load and launch the PRG.


## Code and resources

All code should be built using 6502 Assembly Language.

A library file (x16.inc) is included in the INC folder.

Please comment the code thoroughly so that I can understand it.