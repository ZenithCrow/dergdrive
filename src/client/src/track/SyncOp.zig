const std = @import("std");

const SyncOp = @This();

pub const OpFlags = struct {
    force: bool,
    synced: bool,
    new: bool,
    deleted: bool,

    pub fn perform(self: OpFlags) bool {
        return self.synced | self.new | self.deleted;
    }
};

push: OpFlags,
pull: OpFlags,
excluded: bool,
