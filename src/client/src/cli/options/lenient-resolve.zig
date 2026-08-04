const std = @import("std");

const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;

pub const option: cli.Option = .{
    .long = "--lenient-resolve",
    .desc = "When looking for a matching trusted sign key of a known host, check broader host definitions, such as domain names resolving to ip addresses, or hostnames without port. E.g. for host 'foo.owo:6967', additional hosts are checked for the matching sign key: 'foo.owo', the resolved ip address with or without port. I'd personally avoid using this option :).",
};
