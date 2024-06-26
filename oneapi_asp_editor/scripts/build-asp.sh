#!/bin/bash

## Copyright 2022 Intel Corporation
## SPDX-License-Identifier: MIT

###############################################################################
# Script to generate ASP based on current repoistory state. Script will
# clone required respositories and build OPAE if needed.  #

# Global variables in scripts:
# - Environment variables used as input to control script behvaior
#
#   OFS_PLATFORM_AFU_BBB: root of OFS platform used for ASP
#   LIBOPAE_C_ROOT: path to location where OPAE is installed
#   OPENCL_ASE_SIM: used as input for setup-asp.py to determine if ASE is used
#   OPAE_PLATFORM_ROOT: point to location where platform files are located
#
# - Variables used within script
#
#   SCRIPT_DIR_PATH: path to location of script
#   ASP_ROOT: path to root of ASP repository
#   OFS_PLATFORM_AFU_BBB: path to ofs-platform-afu-bbb repository
###############################################################################

if [ -n "$OFS_ASP_ENV_DEBUG_SCRIPTS" ]; then
  echo "Running ${BASH_SOURCE[0]} with debug logging"
  set -x
fi

SCRIPT_DIR_PATH="$(dirname "$(readlink -e "${BASH_SOURCE[0]}")")"
ASP_ROOT="$(readlink -e "$SCRIPT_DIR_PATH/..")"

# Board variants to generate
if [ "$#" -eq 0 ]; then
  # Generate all board_variants in hardware/ subdirectory if none specified on command line
  # except the common directory
  BOARD_VARIANTS=()
  for dir in $ASP_ROOT/hardware/*/ ; do
    BOARD_VARIANT_NAME=$(basename $dir)
    if [ "$BOARD_VARIANT_NAME" != "common" ]; then	  
      BOARD_VARIANTS+=($BOARD_VARIANT_NAME)  
    fi  
  done
else
  BOARD_VARIANTS=("$@")
fi

for board in "${BOARD_VARIANTS[@]}"; do
  if [ ! -d "$ASP_ROOT/hardware/$board" ]; then
    echo -e "Usage: $0 [board variants]\n"
    echo "Error: '$board' is invalid board variant"
    exit 1
  fi
done


# Use existing OFS_PLATFORM_AFU_BBB or clone ofs-platform-afu-bbb
BUILD_DIR="$ASP_ROOT/build"
mkdir -p "$BUILD_DIR"
if [ -z "$OFS_PLATFORM_AFU_BBB" ]; then
  cd "$BUILD_DIR" || exit
  if [ ! -d "$BUILD_DIR/ofs-platform-afu-bbb" ]; then
    git clone https://github.com/OPAE/ofs-platform-afu-bbb.git -b master ofs-platform-afu-bbb || exit
  fi
  export OFS_PLATFORM_AFU_BBB="$ASP_ROOT/build/ofs-platform-afu-bbb"
fi

# Check that ofs-platform-afu-bbb exist
if [ ! -d "$OFS_PLATFORM_AFU_BBB" ]; then
  echo "Error cannot find ofs-platform-afu-bbb at $OFS_PLATFORM_AFU_BBB"
  exit 1
fi


# If LIBOPAE_C_ROOT is not set then try to detect if OPAE is already installed
# on the system and use that location. Otherwise build OPAE from source.
# Note that this looks for libopae-c.so.2 because that version is required
# and older 1.0 version will not work. In the future this may need to be
# updated to work with newer versions of libopae-c too.
if [ -z "$LIBOPAE_C_ROOT" ]; then
  if /sbin/ldconfig -p | grep libopae-c.so.2 -q && afu_synth=$(command -v afu_synth_setup); then
    LIBOPAE_C_ROOT="$(dirname "$(dirname "$afu_synth")")"
  else
    "$SCRIPT_DIR_PATH/build-opae.sh" || exit
    LIBOPAE_C_ROOT="$ASP_ROOT/build/opae/install"
  fi
fi

# Check that OPAE is installed by looking for required include file
if [ ! -f "$LIBOPAE_C_ROOT/include/opae/fpga.h" ]; then
  echo "Error: cannot find required OPAE files in $LIBOPAE_C_ROOT"
  exit 1
fi
export LIBOPAE_C_ROOT



# Build the MMD or use existing MMD if files already exist
if [ ! -f "$ASP_ROOT/linux64/lib/libintel_opae_mmd.so" ]; then
  "$SCRIPT_DIR_PATH/build-asp-sw.sh" || exit
else
  ldd "$ASP_ROOT/linux64/lib/libintel_opae_mmd.so" | grep -q libopae-c-ase
  ASE_NOT_LINKED="$?"
  if [ -n "$OPENCL_ASE_SIM" ]; then
    if [ "$ASE_NOT_LINKED" == 1 ]; then
      "$SCRIPT_DIR_PATH/build-asp-sw.sh" || exit
    else
      echo "INFO: existing MMD compiled for ASE"
    fi
  elif [ "$ASE_NOT_LINKED" == 0 ]; then
    "$SCRIPT_DIR_PATH/build-asp-sw.sh" || exit
  else
    echo "INFO: existing MMD compiled for hardware"
  fi
fi

# Check that MMD was built
if [ ! -f "$ASP_ROOT/linux64/lib/libintel_opae_mmd.so" ]; then
  echo "Error: MMD was not built correctly"
  exit 1
fi

if [ -z "$OPAE_PLATFORM_ROOT" ]; then
  echo "Error: Must set OPAE_PLATFORM_ROOT environment variable"
  exit 1
fi


# Use existing INTEL_FPGA_BBB or source/extra/intel-fpga-bbb
if [ -z "$INTEL_FPGA_BBB" ]; then
    #export INTEL_FPGA_BBB="$ASP_ROOT/source/extra/intel-fpga-bbb"
    export INTEL_FPGA_BBB="$ASP_ROOT/../common/source/extra/intel-fpga-bbb"
fi

# Check that intel-fpga-bbb exist
if [ ! -d "$INTEL_FPGA_BBB" ]; then
  echo "Error cannot find intel-fpga-bbb at $INTEL_FPGA_BBB"
  exit 1
fi

# Generate ASP
echo "---------------------------------------------------------------"
echo "Generating ASP using setup-asp.py using environment variables:"
echo "LIBOPAE_C_ROOT=\"$LIBOPAE_C_ROOT\""
echo "OPAE_PLATFORM_ROOT=\"$OPAE_PLATFORM_ROOT\""
echo "OPAE_PLATFORM_DB_PATH=\"$OPAE_PLATFORM_DB_PATH\""
echo "OPENCL_ASE_SIM=\"$OPENCL_ASE_SIM\""
echo "OFS_PLATFORM_AFU_BBB=\"$OFS_PLATFORM_AFU_BBB\""
echo "INTEL_FPGA_BBB=\"$INTEL_FPGA_BBB\""
echo "---------------------------------------------------------------"

failed_asps=""
for board in "${BOARD_VARIANTS[@]}"; do
  echo "---------------------------------------------------------------"
  echo -e "Setup ASP for board variant: $board\n"
  if ! python3 "$SCRIPT_DIR_PATH/setup-asp.py" "$board"; then
    failed_asps="${failed_asps:+$failed_asps }$board"
  fi
  echo "---------------------------------------------------------------"
done
if [ -n "$failed_asps" ]; then
  printf 'Error: ASP build failed for...\n'
  # shellcheck disable=SC2086
  printf '    %s\n' $failed_asps
  exit 1
else
  printf '\n\nbuild-asp.sh (and sub-scripts) completed successfully\n\n'
fi
