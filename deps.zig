const std = @import("std");
pub const pkgs = struct {
    pub const zbox = std.build.Pkg{
        .name = "zbox",
        .path = "forks/zbox/src/box.zig",
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "ziglyph",
                .path = ".gyro/ziglyph-jecolon-e5a1f4959447583077ee18b9cfd483e0a4a133ad/pkg/src/ziglyph.zig",
            },
        },
    };

    pub const datetime = std.build.Pkg{
        .name = "datetime",
        .path = ".gyro/zig-datetime-frmdstryr-b52235d4026ead2ce8e2b768daf880f8174f0be5/pkg/datetime.zig",
    };

    pub const clap = std.build.Pkg{
        .name = "clap",
        .path = ".gyro/zig-clap-Hejsil-42433ca7b59c3256f786af5d1d282798b5b37f31/pkg/clap.zig",
    };

    pub const iguanaTLS = std.build.Pkg{
        .name = "iguanaTLS",
        .path = ".gyro/iguanaTLS-alexnask-0d39a361639ad5469f8e4dcdaea35446bbe54b48/pkg/src/main.zig",
    };

    pub const hzzp = std.build.Pkg{
        .name = "hzzp",
        .path = ".gyro/hzzp-truemedian-b4e874ed921f76941dce2870677b713c8e0ebc6c/pkg/src/main.zig",
    };

    pub const tzif = std.build.Pkg{
        .name = "tzif",
        .path = ".gyro/zig-tzif-leroycep-bf91177e6ff7f52cffc44c33b6d755392ed7f9d7/pkg/tzif.zig",
    };

    pub const ziglyph = std.build.Pkg{
        .name = "ziglyph",
        .path = ".gyro/ziglyph-jecolon-e5a1f4959447583077ee18b9cfd483e0a4a133ad/pkg/src/ziglyph.zig",
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        @setEvalBranchQuota(1_000_000);
        inline for (std.meta.declarations(pkgs)) |decl| {
            if (decl.is_pub and decl.data == .Var) {
                artifact.addPackage(@field(pkgs, decl.name));
            }
        }
    }
};

pub const base_dirs = struct {
    pub const zbox = "forks/zbox";
    pub const datetime = ".gyro/zig-datetime-frmdstryr-b52235d4026ead2ce8e2b768daf880f8174f0be5/pkg";
    pub const clap = ".gyro/zig-clap-Hejsil-42433ca7b59c3256f786af5d1d282798b5b37f31/pkg";
    pub const iguanaTLS = ".gyro/iguanaTLS-alexnask-0d39a361639ad5469f8e4dcdaea35446bbe54b48/pkg";
    pub const hzzp = ".gyro/hzzp-truemedian-b4e874ed921f76941dce2870677b713c8e0ebc6c/pkg";
    pub const tzif = ".gyro/zig-tzif-leroycep-bf91177e6ff7f52cffc44c33b6d755392ed7f9d7/pkg";
    pub const ziglyph = ".gyro/ziglyph-jecolon-e5a1f4959447583077ee18b9cfd483e0a4a133ad/pkg";
};
