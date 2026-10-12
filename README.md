```
___  ________  ___       ___  ________  ___          
|\  \|\   ___ \|\  \     |\  \|\   ___ \|\  \         
\ \  \ \  \_|\ \ \  \    \ \  \ \  \_|\ \ \  \        
 \ \  \ \  \ \\ \ \  \    \ \  \ \  \ \\ \ \  \       
  \ \  \ \  \_\\ \ \  \____\ \  \ \  \_\\ \ \  \____  
   \ \__\ \_______\ \_______\ \__\ \_______\ \_______\
    \|__|\|_______|\|_______|\|__|\|_______|\|_______|
 ___  ________  ___       ___  ________  ___          
|\  \|\   ___ \|\  \     |\  \|\   ___ \|\  \         
\ \  \ \  \_|\ \ \  \    \ \  \ \  \_|\ \ \  \        
 \ \  \ \  \ \\ \ \  \    \ \  \ \  \ \\ \ \  \       
  \ \  \ \  \_\\ \ \  \____\ \  \ \  \_\\ \ \  \____  
   \ \__\ \_______\ \_______\ \__\ \_______\ \_______\
    \|__|\|_______|\|_______|\|__|\|_______|\|_______|
```

# Idle

Idle (`idl`) is a node-based configuration language inspired by
[HCL](https://github.com/hashicorp/hcl), [libucl](https://github.com/vstakhov/libucl),
and [KDL](https://kdl.dev/). Nodes contain positional values and named
properties, with optional child bodies and annotations. Values include scalars,
lists, symbols, numbers with units, and expressions.

The native core is implemented in [Zig](https://ziglang.org/). It parses
documents into syntax trees, including expressions, but does not evaluate them.
Applications define their meanings and evaluation. C ABI and WebAssembly
adapters are planned, but not yet implemented.

```idl
server 'api' host='0.0.0.0' port=8080 {
    route '/users' method='GET' {
        handler users.list
    }
}

model Orders {
    table 'tbl_orders'
    fields {
        item_id i32 pk=true default=(uuid())
        amount f32
        create_date datetime
    }
}

action CreateOrder {
    input {
        item_id i32
        amount f32
    }

    output {
        order_id i32
    }
}
```

- [Core specification](docs/idl-spec.md)
- [Language examples](dev/idl-lib/tests/fixtures/kitchen-sink.idl)
- [Core library](dev/idl-lib/README.md)
- [Language server](dev/idl-lsp/README.md)
- [VS Code extension](dev/idl-vscode/README.md)
