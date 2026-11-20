#!/usr/bin/env python3
"""Encode an IPv4 address as an IPv4-mapped or NAT64 IPv6 address."""

import argparse
from ipaddress import IPv4Address, IPv6Address, IPv6Network


WELL_KNOWN = IPv6Network("64:ff9b::/96")
MAPPED = IPv6Network("::ffff:0:0/96")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipv4", type=IPv4Address, help="IPv4 address in dotted decimal")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--nat64", action="store_true", help="use 64:ff9b::/96")
    mode.add_argument("--nat64-prefix", type=IPv6Network, help="use the translator's configured /96")
    args = parser.parse_args()

    if not args.nat64 and args.nat64_prefix is None:
        print(f"::ffff:{args.ipv4}")
        return

    prefix = args.nat64_prefix if args.nat64_prefix is not None else WELL_KNOWN
    if prefix.prefixlen != 96 or prefix == MAPPED:
        parser.error("the NAT64 prefix must be a valid /96 other than ::ffff:0:0/96")
    if prefix == WELL_KNOWN and (not args.ipv4.is_global or args.ipv4.is_multicast):
        parser.error("64:ff9b::/96 requires a globally reachable unicast IPv4 address")

    print(IPv6Address(int(prefix.network_address) | int(args.ipv4)))


if __name__ == "__main__":
    main()
