// See end for licenses
const std = @import("std");
const log = std.log.scoped(.VIRTIO);
const dev = @import("../device.zig");
const reg = @import("../../riscv/reg.zig");
const assert = @import("../../util/debug.zig").assert;

// VirtIO Device IDs from Linux (virtio_ids.h). See end of file for that header
// and license.

const MAGIC_NUMBER = 0x74726976;

pub const devtype = enum(u32) {
	none = 0,
	/// Network Device
	net,
	/// Block Device
	block,
	/// Console Device
	console,
	/// RNG Device
	rng,
	/// Balloon Device
	balloon,
	/// IO Memory Device
	iomem,
	/// Remote Processor Messaging
	rpmsg,
	/// SCSI
	scsi,
	/// 9P Console
	_9p,
	/// WLAN MAC
	mac80211_wlan,
	/// RemoteProc Serial Link
	rproc_serial,
	/// CAIF Device
	caif,
	/// Memory Balloon Device
	memory_balloon,
	/// GPU Device
	gpu,
	/// Clock / Timer
	clock,
	/// Hardware Input Device
	input,
	/// Virtual Socket Device
	vsock,
	/// Cryptography Device
	crypto,
	/// Signal Distrubution Device
	signal_dist,
	/// PStore Device
	pstore,
	/// IO Memory Management Unit
	iommu,
	/// Memory Device
	mem,
	/// Sound Device
	sound,
	/// Filesystem Device
	fs,
	/// PMEM Device
	pmem,
	/// RPMB Device
	rpmb,
	/// Hardware Sim Mac 80211
	mac80211_hwsim,
	/// Video Decoder
	video_encoder,
	/// Video Decoder
	video_decoder,
	/// SCMI
	scmi,
	/// Nitro Secure Module
	nitro_sec_mod,
	/// I2C Adapter
	i2c_adapter,
	/// Watchdog
	watchdog,
	/// CAN
	can,
	/// DMABUF
	dmabuf,
	/// Parameter Server
	param_serv,
	/// Audio Policy Device
	audio_policy,
	/// Bluetooth Device
	bt,
	/// GPIO
	gpio
};

/// Official spec for VIRTIO MMIO registers
pub const mmio_regs = extern struct {
	/// R - Magic Value
	magic_value: u32,

	/// R - Device Version Number
	version: u32,

	/// R - Virtio Subsystem Device ID
	device_id: devtype,
	/// R - Virtio Subsystem Vendor ID
	vendor_id: u32,

	/// R - Flags representing device-supported features
	device_features: u32,
	/// W - Host Feature selection
	device_features_sel: u32,

	_reserved_0x18: [2]u32,

	/// R - Flags representing features understood by driver
	driver_features: u32,
	/// W - Guest feature selection
	driver_features_sel: u32,

	_reserved_0x28: [2]u32,

	/// W - Virtual queue index
	queue_sel: u32,
	/// R - Max virtqueue size
	queue_num_max: u32,
	/// W - Virtqueue size
	queue_num: u32,

	_reserved_0x3c: [2]u32,

	/// RW - Virtqueue ready bit
	queue_ready: u32,

	_reserved_0x48: [2]u32,

	/// W - Queue notifier
	queue_notify: u32,

	_reserved_0x54: [3]u32,

	/// R - Interrupt status
	interrupt_status: u32,
	/// W - Interrupt acknowledge
	interrupt_ack: u32,

	_reserved_0x68: [2]u32,

	/// RW - Device status
	status: status,

	_reserved_0x74: [3]u32,

	/// W - Virtual queue’s Descriptor Area 64 bit long physical address
	queue_desc: u64,

	_reserved_0x8c: [2]u32,

	/// W - Virtual queue’s Driver Area 64 bit long physical address
	queue_driver: u64,

	_reserved_0x9c: [2]u32,

	/// W - Virtual queue’s Device Area 64 bit long physical address
	queue_device: u64,

	/// W - Shared memory id
	shm_sel: u32,
	/// R - Shared memory region 64 bit long length
	shm_len: u64,
	/// R - Shared memory region 64 bit long physical address
	shm_base: u64,

	/// RW - Virtual queue reset bit
	queue_reset: u32,

	_reserved_0xc4: [14]u32,

	config: extern union {
		net: extern struct {
			/// always exists, valid only if VIRTIO_NET_F_MAC is set.
			mac: [6]u8,
			/// only exists if VIRTIO_NET_F_STATUS is set.
			status: u16,
			/// exists if VIRTIO_NET_F_MQ or VIRTIO_NET_F_RSS is set. specifies max number of each transmit and receive virtqueues.
			max_virtqueue_pairs: u16,
			/// exists if VIRTIO_NET_F_MTU is set. specifies max MTU for driver to use.
			mtu: u16,
			/// contains device speed, in units of 1MBit per second. 0x0 - 0x7FFFFFFF. 0xFFFFFFFF for unknown speed. DRIVER MUST REREAD AFTER CONFIG CHANGE NOTIF
			speed: u32,
			/// 0x01 for full duplex, 0x00 for half duplex, 0xFF for unkown duplex. DRIVER MUST REREAD AFTER CONFIG CHANGE NOTIF
			duplex: Duplex,
			/// exists if VIRTIO_NET_F_RSS or VIRTIO_NET_F_HASH_REPORT is set. Specifies max supported length of RSS key in bytes.
			rss_max_key_size: u8,
			/// exists if VIRTIO_NET_F_RSS exists. specifies max number of 16-bit entries in RSS table.
			rss_max_indirection_table_length: u16,
			/// bitmask of supported types. exists if VIRTIO_NET_F_RSS or VIRTIO_NET_F_HASH_REPORT is set.
			supported_hash_types: u32,

			const Duplex = enum(u8) {
				half = 0x00,
				full = 0x01,
				unkown = 0xFF
			};
		},
		blk: extern struct {
			capacity: u64,
			size_max: u32,
			seg_max: u32,
			geometry: extern struct {
				cylinders: u16,
				heads: u8,
				sectors: u8
			},
			blk_size: u32,
			topology: extern struct {
				phys_block_exp: u8,
				alignment_offset: u8,
				min_io_size: u16,
				opt_io_size: u32
			},
			writeback: bool,
			// 1 byte padding
			num_queues: u16,
			max_discard_sectors: u32,
			max_discard_seg: u32,
			discard_sector_alignment: u32,
			max_write_zeroes_sectors: u32,
			max_write_zeroes_seg: u32,
			write_zeroes_may_unmap: bool,
			// 3 byte padding
			max_secure_erase_sectors: u32,
			max_secure_erase_seg: u32,
			secure_erase_sector_alignment: u32
		},
		snd: extern struct {
			/// (driver-read-only) - indicates total number of all available jacks.
			jacks: u32,
			/// (driver-read-only) - indicates total number of all available PCM streams.
			streams: u32,
			/// (driver-read-only) - indicates total number of all available channel maps.
			chmaps: u32
		}
	},


	pub fn notify_avail(regs: *volatile mmio_regs, qid: u32) void {
		reg.fence();
		regs.queue_notify = qid;
	}

	pub fn enable_virtq(regs: *volatile mmio_regs, qid: u32) void {
		regs.queue_sel = qid;
		reg.fence();
		regs.queue_ready = 1;
	}

	pub fn reset_virtq(regs: *volatile mmio_regs, qid: u32) void {
		regs.queue_sel = qid;
		reg.fence();
		regs.queue_reset = 1;
	}

	pub fn attach_virtq(regs: *volatile mmio_regs, qid: u32, len: u16, desc_addr: *virtq_desc, used_addr: usize, avail_addr: usize) void {
		regs.queue_sel = qid;
		reg.fence();
		regs.queue_desc = @intCast(@intFromPtr(desc_addr));
		regs.queue_device = @intCast(used_addr);
		regs.queue_driver = @intCast(avail_addr);
		regs.queue_num = @intCast(len);
		reg.fence();
	}

	pub fn check_feature(regs: *volatile mmio_regs, feat: comptime_int) bool {
		regs.device_features_sel = feat / 32;
		reg.fence();
		return (regs.device_features & (1 << (feat & 31))) > 0;
	}

	pub fn add_feature(regs: *volatile mmio_regs, feat: comptime_int) dev.Error!void {
		regs.device_features_sel = feat / 32;
		reg.fence();
		if (regs.device_features & feat != 0) {
			regs.driver_features_sel = feat / 32;
			reg.fence();
			regs.driver_features |= feat & 31;
			reg.fence();
			return;
		}
		log.warn("Failed to negotiate feature {d}", .{feat});
		return dev.Error.Unsupported;
	}

	pub fn negotiate_features(regs: *volatile mmio_regs, needed: *const FeatureSet, wanted: *const FeatureSet) dev.Error!FeatureSet {
		var enabled = FeatureSet{};
		// Verify that needed features are offered
		for (needed.feats, 0..) |feats, i| {
			if (feats > 0) {
				regs.device_features_sel = @intCast(i);
				regs.driver_features_sel = @intCast(i);
				reg.fence();
				if ((regs.device_features & feats) != feats)
					return dev.Error.Unsupported;
				regs.driver_features |= feats;
				reg.fence();
			}
		}

		// All needed are found
		for (wanted.feats, 0..) |feats, i| {
			if (feats > 0) {
				regs.device_features_sel = @intCast(i);
				regs.driver_features_sel = @intCast(i);
				reg.fence();
				enabled.feats[i] |= regs.device_features & feats;
				regs.driver_features |= enabled.feats[i];
				reg.fence();
			}
		}

		regs.status.features_ok = true;
		assert(regs.status.features_ok, "i just set it tho");

		return enabled;
	}
};

pub const status = packed struct(u32) {
	acknowledge: bool = false,
	driver: bool = false,
	driver_ok: bool = false,
	features_ok: bool = false,
	_reserved0: u2 = 0,
	device_needs_reset: bool = false,
	failed: bool = false,
	_remaining: u24 = 0,
};

pub const F = struct {

	/// Device supports indirect descriptors
	pub const INDIRECT_DESC = 28;
	/// Device supports the event index feature
	pub const EVENT_IDX = 29;
	/// Device supports any virtqueue layout
	pub const ANY_LAYOUT = 27;
	/// Device supports ring reset
	pub const RING_RESET = 40;

	/// Device handles packets with partial checksum.
	/// This “checksum offload” is a common feature on modern network cards.
	pub const NET_CSUM = 0;
	/// Driver handles packets with partial checksum.
	pub const NET_GUEST_CSUM = 1;
	/// Control channel offloads reconfiguration support.
	pub const NET_CTRL_GUEST_OFFLOADS = 2;
	/// Device maximum MTU reporting is supported. If offered by the device,
	/// device advises driver about the value of its maximum MTU. If negotiated,
	/// the driver uses mtu as the maximum MTU value.
	pub const NET_MTU = 3;
	/// Device has given MAC address.
	pub const NET_MAC = 5;
	/// Driver can receive TSOv4. REQUIRES VIRTIO_NET_F_CSUM
	pub const NET_GUEST_TSO4 = 7;
	/// Driver can receive TSOv6. REQUIRES VIRTIO_NET_F_CSUM
	pub const NET_GUEST_TSO6 = 8;
	/// Driver can receive TSO with ECN.
	/// REQUIRES VIRTIO_NET_F_GUEST_TSO4 or VIRTIO_NET_F_GUEST_TSO6
	pub const NET_GUEST_ECN = 9;
	/// Driver can receive UFO. REQUIRES VIRTIO_NET_F_CSUM
	pub const NET_GUEST_UFO = 10;
	/// Device can receive TSOv4. REQUIRES VIRTIO_NET_F_CSUM
	pub const NET_HOST_TSO4 = 11;
	/// Device can receive TSOv6. REQUIRES VIRTIO_NET_F_CSUM
	pub const NET_HOST_TSO6 = 12;
	/// Device can receive TSO with ECN.
	/// REQUIRES VIRTIO_NET_F_HOST_TSO4 or VIRTIO_NET_F_HOST_TSO6
	pub const NET_HOST_ECN = 13;
	/// Device can receive UFO. REQUIRES VIRTIO_NET_F_CSUM
	pub const NET_HOST_UFO = 14;
	/// Driver can merge receive buffers.
	pub const NET_MRG_RXBUF = 15;
	/// Configuration status field is available.
	pub const NET_STATUS = 16;
	/// Control channel is available.
	pub const NET_CTRL_VQ = 17;
	/// Control channel RX mode support. REQUIRES VIRTIO_NET_F_CTRL_VQ
	pub const NET_CTRL_RX = 18;
	/// Control channel VLAN filtering. REQUIRES VIRTIO_NET_F_CTRL_VQ
	pub const NET_CTRL_VLAN = 19;
	/// Driver can send gratuitous packets. REQUIRES VIRTIO_NET_F_CTRL_VQ
	pub const NET_GUEST_ANNOUNCE = 21;
	/// Device supports multiqueue with automatic receive steering. REQUIRES VIRTIO_NET_F_CTRL_VQ
	pub const NET_MQ = 22;
	/// Set MAC address through control channel. REQUIRES VIRTIO_NET_F_CTRL_VQ
	pub const NET_CTRL_MAC_ADDR = 23;
	/// Device can receive USO packets. Unlike UFO (fragmenting the packet) the USO splits large
	/// UDP packet to several segments when each of these smaller packets has UDP header.
	pub const NET_HOST_USO = 56;
	/// Device can report per-packet hash value and a type of calculated hash.
	pub const NET_HASH_REPORT = 57;
	/// Driver can provide the exact hdr_len value. Device benefits from knowing the exact header length.
	pub const NET_GUEST_HDRLEN = 59;
	/// Device supports RSS (receive-side scaling) with Toeplitz hash calculation
	/// and configurable hash parameters for receive steering. REQUIRES VIRTIO_NET_F_CTRL_VQ.
	/// Useful for Multi CPU or High Throughput
	pub const NET_RSS = 60;
	/// Device can process duplicated ACKs and report number of coalesced segments and duplicated ACKs.
	pub const NET_RSC_EXIT = 61;
	/// Device may act as a standby for a primary device with the same MAC address.
	pub const NET_STANDBY = 62;
	/// Device reports speed and duplex.
	pub const NET_SPEED_DUPLEX = 63;

	/// Maximum size of any single segment is in size_max.
	pub const BLK_SIZE_MAX = 1;
	/// Maximum number of segments in a request is in seg_max.
	pub const BLK_SEG_MAX = 2;
	/// Disk-style geometry specified in geometry.
	pub const BLK_GEOMETRY = 4;
	/// Block device is read-only.
	pub const BLK_RO = 5;
	/// Block size of disk is in blk_size.
	pub const BLK_BLK_SIZE = 6;
	/// Block device supports flush command.
	pub const BLK_FLUSH = 9;
	/// Device exports information on optimal I/O alignment.
	pub const BLK_TOPOLOGY = 10;
	/// Device can toggle its cache between writeback and writethrough modes.
	pub const BLK_CONFIG_WCE = 11;
	/// Device supports multiqueue.
	pub const BLK_MQ = 12;
	/// Block device supports discard command.
	pub const BLK_DISCARD = 13;
	/// Device can support write zeroes command, maximum write zeroes
	/// sectors size in max_write_zeroes_sectors and maximum
	/// write zeroes segment number in max_write_zeroes_seg.
	pub const BLK_WRITE_ZEROES = 14;
	/// Device supports providing storage lifetime information.
	pub const BLK_LIFETIME = 15;
	/// Device supports secure erase command, maximum
	/// erase sectors count in max_secure_erase_sectors
	/// and maximum erase segment number in max_secure_erase_seg.
	pub const BLK_SECURE_ERASE = 16;
};

pub const virtq_desc = extern struct {
	/// guest-physical address
	addr: u64 = 0,
	len: u32 = 0,
	flags: desc_features = .{},
	next: i16 = 0,
};

pub const desc_features = packed struct(u16) {
	next: bool = false,
	write: bool = false,
	indirect: bool = false,
	_remaining: u13 = 0
};

/// Comptime-resolved variable-size avail virtq
pub fn virtq_avail(comptime len: comptime_int) type {
	return extern struct {
		flags: u16 = 0,
		idx: u16 = 0,
		ring: [len]u16 = [_]u16{0} ** len
	};
}

/// Comptime-resolved variable-size used virtq
pub fn virtq_used(comptime len: comptime_int) type {
	const elem = extern struct {
		id: u32 = 0,
		len: u32 = 0
	};
	return extern struct {
		flags: u16 = 0,
		idx: u16 = 0,
		ring: [len]elem = [_]elem{.{}} ** len
	};
}

//
// My Stuff
//

pub const FeatureSet = struct {
	feats: [4]u32 = [4]u32{0,0,0,0},

	pub fn init(features: anytype) FeatureSet {
		var set: FeatureSet = .{};
		inline for (features) |feat| set.add(feat);
		return set;
	}

	pub fn add(set: *FeatureSet, feat: comptime_int) void {
		set.feats[feat/32] |= 1 << (feat & 31);
	}

	pub fn has(set: *const FeatureSet, feat: comptime_int) bool {
		return (set.feats[feat/32] & (1 << (feat & 31))) != 0;
	}
};

pub const Error = (dev.Error || std.mem.Allocator.Error);

/// General attach function for all supported VirtIO devices
pub fn attach(regs: *volatile mmio_regs, irqno: u32, allocator: *const std.mem.Allocator) Error!void {
	if (regs.magic_value != MAGIC_NUMBER) {
		log.err("Incorrect VirtIO Magic Number", .{});
		return dev.Error.NotFound;
	}

	if (regs.version != 2) {
		log.err("Unsupported VirtIO version ({d} != 2)", .{regs.version});
		return dev.Error.Unsupported;
	}

	if (regs.device_id == .none) {
		log.warn("Device id for {*} is none. Returning...", .{regs});
		return;
	}

	regs.status = .{}; // reset
	regs.status.acknowledge = true;

	log.info("Attempting to attach '{s}'.", .{@tagName(regs.device_id)});
	const attach_fn: *const fn (*volatile mmio_regs, u32, *const std.mem.Allocator) (dev.Error || std.mem.Allocator.Error)!void = switch (regs.device_id) {
		// .net => @panic("NET unfinished"),
		.block => @import("vioblk.zig").attach,
		.rng => @import("viorng.zig").attach,
		// .sound => @panic("SND unfinished"),
		// .gpu => @panic("GPU unfinished"),
		// .input => @panic("HID unfinished"),
		// .console => @panic("CONS unfinished"),
		else => return dev.Error.Unsupported
	};

	regs.status.driver = true;
	reg.fence();

	try attach_fn(regs, irqno, allocator);

	regs.status.driver_ok = true;
	reg.fence();

	log.info("Attached '{s}'", .{@tagName(regs.device_id)});
}

// An interface for efficient virtio implementation.
//
// This header is BSD licensed so anyone can use the definitions
// to implement compatible drivers/servers.
//
// Copyright 2007, 2009, IBM Corporation
// Copyright 2011, Red Hat, Inc
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
// 3. Neither the name of IBM nor the names of its contributors
//    may be used to endorse or promote products derived from this software
//    without specific prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ``AS IS'' AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED.  IN NO EVENT SHALL IBM OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
// OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
// HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
// LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
// OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
// SUCH DAMAGE.
//

// Virtio IDs
//
// This header is BSD licensed so anyone can use the definitions to implement
// compatible drivers/servers.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
// 3. Neither the name of IBM nor the names of its contributors
//    may be used to endorse or promote products derived from this software
//    without specific prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ``AS IS'' AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED.  IN NO EVENT SHALL IBM OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
// OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
// HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
// LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
// OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
// SUCH DAMAGE.
