const std = @import("std");
const IO = @import("../api/io.zig");
const log = std.log.scoped(.EXT2);
const DLL = @import("../util/list.zig").DLL;

const Cache =  @import("./cache.zig");

const EXT2 = @This();

const ROOT_INODE = 2;

// Types

const Superblock = packed struct {
	/// Total number of inodes in file system
	n_inodes: u32,
	/// Total number of Blocks in file system
	n_blocks: u32,
	/// Total number of Superuser Reserved Blocks in file system
	n_superuser_blocks: u32,
	/// Total number of unallocated blocks
	n_unallocated_blocks: u32,
	/// Total number of unallocated inodes
	n_unallocated_inodes: u32,

	/// Block number of the block containing the superblock
	/// (also the starting block number, NOT always zero.)
	superblock_number: u32,

	/// log2 (block size) - 10. (In other words, the number to
	/// shift 1,024 to the left by to obtain the block size)
	log2blksz_10: u32,
	/// log2 (fragment size) - 10. (In other words, the number to
	/// shift 1,024 to the left by to obtain the fragment size)
	log2fragsz_10: u32,

	/// Number of blocks in each block group
	blocks_per_group: u32,
	/// Number of fragments in each block group
	frags_per_group: u32,
	/// Number of inodes in each block group
	inodes_per_group: u32,

	/// Last mount time (in POSIX time)
	last_mounted: u32,
	/// Last written time (in POSIX time)
	last_written: u32,

	/// Number of times the volume has been mounted since
	/// its last consistency check (fsck)
	mounts_since_fsck: u16,
	/// Number of mounts allowed before a consistency
	/// check (fsck) must be done
	mounts_until_fsck: u16,

	/// Ext2 signature (0xef53), used to help confirm the
	/// presence of Ext2 on a volume
	ext2_signature: u16 = 0xef53,

	/// File system state (see below)
	fs_state: State,
	/// What to do when an error is detected (see below)
	how_to_handle: ErrHandle,

	/// Minor portion of version (combine with Major portion
	/// below to construct full version field)
	minor_version: u16,

	/// POSIX time of last consistency check (fsck)
	last_checked: u32,
	/// Interval (in POSIX time) between forced consistency checks (fsck)
	forced_check_interval: u32,

	/// Operating system ID from which the filesystem on this volume was created (see below)
	creator_os: CreatorOS,

	/// Major portion of version (combine with Minor portion
	/// above to construct full version field)
	major_version: u32,

	/// User ID that can use reserved blocks
	reserved_uid: u16,
	/// Group ID that can use reserved blocks
	reserved_gid: u16,

	// EXTENDED SECTION
	// when major version >= 1

	/// First non-reserved inode in file system. (In versions < 1.0, this is fixed as 11)
	first_nonreserved_inode: u32 = 11,
	/// Size of each inode structure in bytes. (In versions < 1.0, this is fixed as 128)
	inode_size: u16 = 128,
	/// Block group that this superblock is part of (if backup copy)
	superblock_group: u16,

	/// Optional features present (features that are not required to read or write,
	/// but usually result in a performance increase. see below)
	optional_features: OptionalFeatures,

	/// Required features present (features that are required to
	/// be supported to read or write. see below)
	required_features: RequiredFeatures,

	ro_features: ReadOnlyFeatures,

	/// File system ID (what is output by blkid)
	fs_id: [16]u8,
	/// Volume name (C-style string: characters terminated by a 0 byte)
	volume_name: [16:0]u8,
	/// Path volume was last mounted to (C-style string: characters terminated by a 0 byte)
	last_mount_path: [64:0]u8,
	/// Compression algorithms used (see Required features above)
	compression_algos: u32,
	/// Number of blocks to preallocate for files
	file_prealloc: u8,
	/// Number of blocks to preallocate for directories
	dir_prealloc: u8,

	_unused1: [2]u8 = undefined,

	/// Journal ID (same style as the File system ID above)
	journal_id: [16]u8,
	/// Journal inode
	journal_inode: u32,
	/// Journal device,
	journal_device: u32,
	/// Head of orphan inode list
	orphan_head: u32,

	_unused2: [1024 - 236]u8 = undefined,

	const State = enum(u16) {
		/// File system is clean
		clean = 1,
		/// File system has errors
		has_error = 2,
	};

	const ErrHandle = enum(u16) {
		/// Ignore the error (continue on)
		ignore = 1,
		/// Remount file system as read-only
		remount_ro = 2,
		/// Kernel panic
		panic = 3
	};

	const CreatorOS = enum(u16) {
		linux = 0,
		/// GNU Hurd, a replacement for UNIX
		hurd = 1,
		/// an operating system developed by Rémy Card, one of the developers of ext2
		masix = 2,
		freebsd = 3,
		/// Other "Lites" (BSD4.4-Lite derivatives such as NetBSD, OpenBSD, XNU/Darwin, etc.)
		other = 4,
	};

	/// These are optional features for an implementation to support, but offer
	/// performance or reliability gains to implementations that do support them.
	const OptionalFeatures = packed struct(u32) {
		/// Preallocate some number of (contiguous?) blocks (see `dir_prealloc` in the superblock)
		/// to a directory when creating a new one (to reduce fragmentation?)
		prealloc_dir: bool,
		/// AFS server inodes exist
		afs_exists: bool,
		/// File system has a journal (Ext3)
		journaled: bool,
		/// Inodes have extended attributes
		extended_inodes: bool,
		/// File system can resize itself for larger partitions
		resizable: bool,
		/// Directories use hash index
		hashed_dirs: bool
	};

	/// These features if present on a file system are required to be supported by an
	/// implementation in order to correctly read from or write to the file system.
	const RequiredFeatures = packed struct(u32) {
		/// Compression is used
		compression_used: bool,
		/// Directory entries contain a type field
		dentry_types: bool,
		/// File system needs to replay its journal
		journal_replay: bool,
		/// File system uses a journal device
		journal_device: bool
	};

	/// These features, if present on a file system, are required in order for an implementation
	/// to write to the file system, but are not required to read from the file system.
	const ReadOnlyFeatures = packed struct(u32) {
		/// Sparse superblocks and group descriptor tables
		sparse: bool,
		/// File system uses a 64-bit file size
		x64: bool,
		/// Directory contents are stored in the form of a Binary Tree
		binary_tree: bool
	};

	fn blksz(self: *Superblock) u32 {
		return 1 << (self.log2blksz_10 + 10);
	}

	fn fragsz(self: *Superblock) u32 {
		return 1 << (self.log2fragsz_10 + 10);
	}

	test "correct size" {
		try std.testing.expectEqual(1024, @sizeOf(Superblock));
	}

	/// The table is located in the block immediately following the Superblock.
	/// So if the block size (determined from a field in the superblock) is 1024
	/// bytes per block, the Block Group Descriptor Table will begin at block 2.
	/// For any other block size, it will begin at block 1. Remember that blocks
	/// are numbered starting at 0, and that block numbers don't usually correspond
	/// to physical block addresses.
	fn find_descriptor_table(self: *Superblock) u32 {
		return if (self.blksz() == 1024) 2 else 1;
	}
};

/// A Block Group Descriptor contains information regarding where
/// important data structures for that block group are located.
const BlockGroupDescriptor = packed struct {
	/// Block address of block usage bitmap
	block_bitmap_addr: u32,
	/// Block address of inode usage bitmap
	inode_bitmap_addr: u32,
	/// Starting block address of inode table
	inode_table_addr: u32,
	/// Number of unallocated blocks in group
	n_unallocated_blocks: u16,
	/// Number of unallocated inodes in group
	n_unallocated_inodes: u16,
	/// Number of directories in group
	n_dirs: u16,

	_unused: [32-18]u8 = undefined
};

const Inode = packed struct {
	/// Type and Permissions (see below)
	perm: Perms,
	type: Type,

	/// User ID
	uid: u16,

	/// Lower 32 bits of size in bytes
	size_lower: u32,

	/// Last Access Time (in POSIX time)
	last_access: u32,
	/// Creation Time (in POSIX time)
	creation_time: u32,
	/// Last Modification time (in POSIX time)
	last_modified: u32,
	/// Deletion time (in POSIX time)
	deletion_time: u32,

	/// Group ID
	gid: u16,

	/// Count of hard links (directory entries) to this inode.
	/// When this reaches 0, the data blocks are marked as unallocated.
	n_links: u16,

	/// Count of disk sectors (not Ext2 blocks) in use by this inode, not counting
	/// the actual inode structure nor directory entries linking to the inode.
	n_sectors: u32,

	/// Flags (see below)
	flags: Flags,

	os_val1: u32,

	/// Direct block pointers
	direct: [12]u32,
	/// Singly Indirect Block Pointer (Points to a block that is a list of block pointers to data)
	indirect: u32,
	/// Doubly Indirect Block Pointer (Points to a block that is a list of block pointers to Singly Indirect Blocks)
	dindirect: u32,
	/// Triply Indirect Block Pointer (Points to a block that is a list of block pointers to Doubly Indirect Blocks)
	trindirect: u32,

	/// Generation number (Primarily used for NFS)
	generation: u32,

	/// In Ext2 version 0, this field is reserved. In version >= 1,
	/// Extended attribute block (File ACL).
	file_acl: u32,

	/// In Ext2 version 0, this field is reserved. In version >= 1,
	/// Upper 32 bits of file size (if feature bit set) if it's a file,
	/// Directory ACL if it's a directory
	upper_size_or_dir_acl: u32,

	/// Block address of fragment
	frag_block_addr: u32,

	os_val2: u32,


	const Type = enum(u4) {
		FIFO = 0x1,
		CharacterDevice = 0x2,
		Directory = 0x4,
		BlockDevice = 0x6,
		RegularFile = 0x8,
		Symlink = 0xA,
		UnixSocket = 0xC
	};

	const Perms = packed struct(u12) {
		other_exec: bool,
		other_write: bool,
		other_read: bool,
		group_exec: bool,
		group_write: bool,
		group_read: bool,
		user_exec: bool,
		user_write: bool,
		user_read: bool,
		sticky_bit: bool,
		set_gid: bool,
		set_uid: bool
	};

	const Flags = packed struct(u32) {
		/// Secure deletion (not used)
		secure_delete: bool,
		/// Keep a copy of data when deleted (not used)
		keep_after_delete: bool,
		/// File compression (not used)
		compression: bool,
		/// Synchronous updates—new data is written immediately to disk
		immediate_write: bool,
		/// Immutable file (content cannot be changed)
		immutable: bool,
		/// Append only
		append_only: bool,
		/// File is not included in 'dump' command
		hidden: bool,
		/// Last accessed time should not updated
		freeze_time: bool,

		_reserved: u8,

		/// Hash indexed directory
		hash_dir: bool,
		/// AFS directory
		afs_dir: bool,
		/// Journal file data
		journaled: bool
	};
};

const DentryType = enum(u8) {
	unknown = 0,
	file,
	directory,
	char_device,
	block_device,
	fifo,
	socket,
	symlink
};

const Dentry = packed struct {
	inode: u32,
	densz: u16,
	name_length_lsb: u8,
	type_or_length: extern union {
		type: DentryType,
		name_length_msb: u8
	},

	fn name_size(self: *Dentry, msb: bool) u16 {
		return @bitCast([2]u8{ self.name_length_lsb, if (msb) self.type_or_length.name_length_msb else 0 });
	}

	fn name(self: *Dentry, msb: bool) []const u8 {
		return @as([*]u8, @ptrCast(self))[@sizeOf(Dentry)..self.size(msb)];
	}

	fn size(self: *Dentry, msb: bool) u16 {
		return @sizeOf(Dentry) + self.name_size(msb);
	}

	/// UNSAFE: does not check for boundary
	fn next(self: *Dentry, msb: bool) *Dentry {
		return @ptrFromInt(@intFromPtr(self) + self.size(msb));
	}
};

superblock: Superblock,
blksz: u64,

cache: Cache,

// pub fn mount()

inline fn block_size(self: *EXT2, indirection: u64) u64 {
	return self.blksz * std.math.pow(u64, self.blksz / 32, indirection);
}
