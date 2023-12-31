# Kvm
Kvm (Karel Virtual Machine) is a blazingly fast interpreter for the Robot Karel language written in zig.

Kvm is only a bare compiler + interpreter library, to use it beyond just loading a karel-lang file and executing one function, see projects that incorporate Kvm like [PyKarel](https://github.com/C2Coder/PyKarel99) by [@C2Coder](https://github.com/C2Coder/).

## Building
You need to download the newest zig compiler. (currently 0.11.0)

To clone and build:
```sh
git clone https://github.com/Caszual/Kvm.git
cd Kvm/
zig build -Doptimize=ReleaseFast
```

After the build completes, to run the demo:
```sh
./zig-out/bin/Kvm
```

Or use it in your projects using the dynamic library (with a C api) in `./zig-out/lib/`

### Debug
To profile your Karel code or to debug the Vm build with `-Doptimize=Debug`
```sh
zig build -Doptimize=Debug
```

In this config the Kvm will print every bytecode instruction it executes together with its arguments.
**Warning**: This Config will slow down the Vm a lot and spam the output terminal.
