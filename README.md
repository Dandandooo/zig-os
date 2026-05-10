
<div align="center" style="background-color: transparent;">
  <!-- <img width="256" height="125" alt="eyes" src="https://github.com/user-attachments/assets/59322ef2-6960-4fbc-bafb-5f00452c677e" /> -->

```zig
.o8                                    
"888                                    
 888oooo.   .ooooo.   .ooooo.   .oooo.o 
 d88' `88b d88' `88b d88' `88b d88(  "8 
 888   888 888   888 888   888 `"Y88b.  
 888   888 888   888 888   888 o.  )88b 
 `Y8bod8P' `Y8bod8P' `Y8bod8P' 8""888P' 
```

⚡ **the _barely_ operational operating system** ⚡

by Dandandooo

---
![image](https://img.shields.io/badge/zig-F7A41D?style=for-the-badge&logo=zig&logoColor=white)

</div>

# What is BOOS? 🦋
BOOS is a simple UNIX-inspired kernel written in zig. It follows the RISC-V architecture, with plans to support ARM or x86
so I can run it plug-'n-play with my devices.


When completed, this project shall be called the _brilliantly operational operating system_.

# Features ⚙️

> [!NOTE]
> this list is expanding and I don't write READMEs often, so it may be out of date

- Threads
- Real Time
- UART Console
  - Comes with pretty printing
- VirtIO
  - RNG Device
  - Block Device
 
# Usage 🗣️

This project requires zig version `0.16.0`. Previous versions will not work.

Commands to get running (assuming you have zig 0.16.0 and just):
```
git clone https://github.com/Dandandooo/zig-os
cd zig-os
just run
```

## Build Targets

Build targets are separated between `build.zig` and `justfile`, with common operations being referenced in both. The easiest way to interact is by running `just` to list the 

To get started, run the following commands

- `just run` - Run the kernel normally, compiled in debug mode
- `just test` - Compile with test functions and run tests
- `just debug` - Compile with tests and gdb hook
- `just gdb` - Start gdb with breakpoint at panic
- `just addr <addr>` - Returns line in regular executable of the address provided
- `just taddr <addr>` - Same as above but for test executable
- `just size` - Print size of kernel executable
- `just tsize` - Print size of kernel-test executable
- `just ktfs` - Compile a set of files into the KTFS file system (part of UIUC ECE 391)
- `zig build docs` - Generate documentation using Zig's documentation builder

# Why? 🤷‍♂️
BOOS is a solo project I am undertaking because I like developing systems from scratch. I was inspired by UIUC's ECE 391 class
that taught me to think about systems more directly, and I fell in love with the kernel I wrote.

Also, I wanted to learn Zig. It is a cool new language with a lot of potential.

## Acknowledgements
Much of this kernel is inspired by code written for UIUC's ECE 391 class. Thank you to my partners in the project.
