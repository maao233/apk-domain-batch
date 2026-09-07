from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.serialization import Encoding
import hashlib
import struct
import sys

pem = open(sys.argv[1], "rb").read()
cert = x509.load_pem_x509_certificate(pem, default_backend())
der = cert.subject.public_bytes(Encoding.DER)
digest = hashlib.md5(der).digest()
h = struct.unpack("<I", digest[:4])[0]
print("%08x" % h)
