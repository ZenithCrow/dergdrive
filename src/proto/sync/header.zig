const std = @import("std");

pub const header_title_size = 4;
pub const DataLenT = u32;
pub const data_len_size = @sizeOf(DataLenT);
pub const header_size = header_title_size + data_len_size;
