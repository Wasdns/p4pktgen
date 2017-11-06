/* -*- mode: P4_16 -*- */
/*
Copyright 2017 Cisco Systems, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include <core.p4>
#include <v1model.p4>

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

const bit<16> ETHERTYPE_IPV4 = 0x0800;

const bit<2> NEXTHOP_TYPE_DROP           = 0;
const bit<2> NEXTHOP_TYPE_L2PTR          = 1;
const bit<2> NEXTHOP_TYPE_ECMP_GROUP_IDX = 2;

struct fwd_metadata_t {
    bit<16> hash1;
    bit<2>  nexthop_type;
    bit<10> ecmp_group_idx;
    bit<8>  ecmp_path_selector;
    bit<32> l2ptr;
    bit<24> out_bd;
}

struct metadata {
    fwd_metadata_t fwd_metadata;
}

struct headers {
    ethernet_t ethernet;
    ipv4_t     ipv4;
}

action my_drop() {
    mark_to_drop();
}

parser ParserImpl(packet_in packet,
                  out headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata)
{
    state start {
        transition parse_ethernet;
    }
    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            ETHERTYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}

//#include "ones-comp-code.p4"
#include "ones-comp-code-issue983-workaround.p4"

control ipv4_sanity_checks(in ipv4_t ipv4) {
    bit<16> correctChecksum;
    apply {
        ones_comp_sum_b144.apply(correctChecksum,
            ipv4.version ++ ipv4.ihl ++ ipv4.diffserv ++
            ipv4.totalLen ++
            ipv4.identification ++
            ipv4.flags ++ ipv4.fragOffset ++
            ipv4.ttl ++ ipv4.protocol ++
            //ipv4.hdrChecksum ++ // intentionally leave this out
            ipv4.srcAddr ++
            ipv4.dstAddr);
        // Correct IPv4 header checksum is one's complement
        // (i.e. bit-wise negation) _of_ the one's complement sum
        // calculated above.
        correctChecksum = ~correctChecksum;

        if (ipv4.version != 4 ||
            ipv4.ihl != 5 ||
            ipv4.totalLen < 20 ||
            ipv4.ttl == 0 ||
            // & 0xffff on next line are to work around p4c issue #983
            (ipv4.hdrChecksum & 0xffff) != (correctChecksum & 0xffff))
        {
            mark_to_drop();
            exit;
        }
    }
}

control compute_ipv4_hashes(out bit<16> hash1, in headers hdr) {
    apply {
//        hash(hash1, HashAlgorithm.crc16,
//             (bit<16>) 0, { hdr.ipv4.srcAddr,
//                            hdr.ipv4.dstAddr,
//                            hdr.ipv4.protocol },
//             (bit<32>) 65536);
        // Use a hash function that is not as high quality as
        // something like a CRC, but is simple to calculate with a
        // small P4_16 arithmetic expression.
        hash1 = (hdr.ipv4.srcAddr[31:16] + hdr.ipv4.srcAddr[15:0] +
                 hdr.ipv4.dstAddr[31:16] + hdr.ipv4.dstAddr[15:0] +
                 (bit<16>) hdr.ipv4.protocol);
    }
}

control ingress(inout headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {
    action set_l2ptr(bit<32> l2ptr) {
        meta.fwd_metadata.nexthop_type = NEXTHOP_TYPE_L2PTR;
        meta.fwd_metadata.l2ptr = l2ptr;
    }
    action set_ecmp_group_idx(bit<10> ecmp_group_idx) {
        meta.fwd_metadata.nexthop_type = NEXTHOP_TYPE_ECMP_GROUP_IDX;
        meta.fwd_metadata.ecmp_group_idx = ecmp_group_idx;
    }
    action ipv4_da_lpm_drop() {
        meta.fwd_metadata.nexthop_type = NEXTHOP_TYPE_DROP;
        my_drop();
    }
    table ipv4_da_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            set_l2ptr;
            set_ecmp_group_idx;
            ipv4_da_lpm_drop;
        }
        default_action = ipv4_da_lpm_drop;
    }

    action set_ecmp_path_idx(bit<8> num_paths_mask) {
//        hash(meta.fwd_metadata.ecmp_path_selector, HashAlgorithm.identity,
//             (bit<16>) 0, { meta.fwd_metadata.hash1 }, (bit<32>)num_paths);
        meta.fwd_metadata.ecmp_path_selector =
            ((meta.fwd_metadata.hash1[15:8] ^ meta.fwd_metadata.hash1[7:0]) &
             num_paths_mask);
    }
    table ecmp_group {
        key = {
            meta.fwd_metadata.ecmp_group_idx: exact;
        }
        actions = {
            set_ecmp_path_idx;
            set_l2ptr;
        }
    }

    table ecmp_path {
        key = {
            meta.fwd_metadata.ecmp_group_idx    : exact;
            meta.fwd_metadata.ecmp_path_selector: exact;
        }
        actions = {
            set_l2ptr;
        }
    }

    action set_bd_dmac_intf(bit<24> bd, bit<48> dmac, bit<9> intf) {
        meta.fwd_metadata.out_bd = bd;
        hdr.ethernet.dstAddr = dmac;
        standard_metadata.egress_spec = intf;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }
    table mac_da {
        key = {
            meta.fwd_metadata.l2ptr: exact;
        }
        actions = {
            set_bd_dmac_intf;
            my_drop;
        }
        default_action = my_drop;
    }

    apply {
        if (hdr.ipv4.isValid()) {
            ipv4_sanity_checks.apply(hdr.ipv4);
            compute_ipv4_hashes.apply(meta.fwd_metadata.hash1, hdr);
            switch (ipv4_da_lpm.apply().action_run) {
                ipv4_da_lpm_drop: { exit; }
            }
            if (meta.fwd_metadata.nexthop_type != NEXTHOP_TYPE_L2PTR) {
                ecmp_group.apply();
                if (meta.fwd_metadata.nexthop_type != NEXTHOP_TYPE_L2PTR) {
                    ecmp_path.apply();
                }
            }
            mac_da.apply();
        }
    }
}

control egress(inout headers hdr,
               inout metadata meta,
               inout standard_metadata_t standard_metadata)
{
    action rewrite_mac(bit<48> smac) {
        hdr.ethernet.srcAddr = smac;
    }
    table send_frame {
        key = {
            meta.fwd_metadata.out_bd: exact;
        }
        actions = {
            rewrite_mac;
            my_drop;
        }
        default_action = my_drop;
    }

    apply {
        send_frame.apply();
    }
}

control DeparserImpl(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}

control verifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

control computeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(hdr.ipv4.ihl == 5,
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
                hdr.ipv4.totalLen,
                hdr.ipv4.identification,
                hdr.ipv4.flags, hdr.ipv4.fragOffset,
                hdr.ipv4.ttl, hdr.ipv4.protocol,
                hdr.ipv4.srcAddr,
                hdr.ipv4.dstAddr
            },
            hdr.ipv4.hdrChecksum, HashAlgorithm.csum16);
    }
}

V1Switch(ParserImpl(),
         verifyChecksum(),
         ingress(),
         egress(),
         computeChecksum(),
         DeparserImpl()) main;
