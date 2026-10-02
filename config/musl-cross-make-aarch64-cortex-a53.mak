# Pinned musl-cross-make configuration for the aarch64 Cortex-A53 target
# (arm_cortex-a53 opkg architecture). This mirrors the arm_cortex-a9 config so
# that the static dnsmasq recipe builds both of the fork's architectures from
# the same pinned tool versions. Copy to musl-cross-make/config.mak before
# building. Every version below has a sha1 in musl-cross-make/hashes at
# submodule commit fe915821.
TARGET = aarch64-linux-musl

GCC_VER = 11.2.0
BINUTILS_VER = 2.33.1
MUSL_VER = 1.2.3
GMP_VER = 6.1.2
MPC_VER = 1.1.0
MPFR_VER = 4.0.2
LINUX_VER = headers-4.19.88-1

# Default code generation: Cortex-A53 (AArch64, LP64, hard-float FP/NEON as the
# only AArch64 ABI), so libc, libgcc and every program match the arm_cortex-a53
# userland. AArch64 has no soft-float variant, so (unlike the a9 config) there
# is no --with-float.
GCC_CONFIG += --with-cpu=cortex-a53

# Build musl's libc.a and libgcc as PIE code so programs can be linked as
# static PIE (ASLR). Programs linked with plain -static still come out as
# fixed-address static executables.
GCC_CONFIG += --enable-default-pie

# Smaller, deterministic toolchain build.
COMMON_CONFIG += CFLAGS="-g0 -O2" CXXFLAGS="-g0 -O2" LDFLAGS="-s"
COMMON_CONFIG += --disable-nls
GCC_CONFIG += --disable-libquadmath --disable-decimal-float --disable-multilib
