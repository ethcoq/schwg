import base64
import os
import random
import ipaddress
import sys


def random_wg_public_key():
    # 32 octets encodés en Base64
    return base64.b64encode(os.urandom(32)).decode()


def random_ipv4():
    return str(ipaddress.IPv4Address(random.getrandbits(32)))


def random_cidr():
    return f"{random_ipv4()}/{random.randint(32, 32)}"


def random_endpoint():
    return f"{random_ipv4()}:{random.randint(1024, 65535)}"


def generate_pair(i):
    return f"""[Peer]
PublicKey = {random_wg_public_key()}
Endpoint = {random_endpoint()}
AllowedIPs = {random_cidr()}

"""


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <n> <output_file>")
        sys.exit(1)

    n = int(sys.argv[1])
    output_file = sys.argv[2]

    with open(output_file, "w") as f:
        for i in range(1, n + 1):
            f.write(generate_pair(i))

    print(f"{n} peers écrits dans {output_file}")


if __name__ == "__main__":
    main()