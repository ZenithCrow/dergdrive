const std = @import("std");

const SyncOp = @This();

pub const OpFlags = struct {
    force: bool,
    synced: bool,
    new: bool,
    deleted: bool,
    excluded: bool,

    pub fn perform(self: OpFlags) bool {
        return self.synced | self.new | self.deleted | self.excluded;
    }
};

push: OpFlags,
pull: OpFlags,
