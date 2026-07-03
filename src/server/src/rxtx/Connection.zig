const dergdrive = @import("dergdrive");
const SecAuth = dergdrive.SecAuth;

const ConnectionWorker = @import("ConnectionWorker.zig");

worker: ConnectionWorker,
sec_auth: SecAuth,
