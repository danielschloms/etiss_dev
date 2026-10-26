#!/usr/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CDSL_DIR="$PROJECT_ROOT/etiss_arch_riscv"
M2ISAR_DIR="$PROJECT_ROOT/M2-ISA-R"

source $M2ISAR_DIR/venv/bin/activate
coredsl2_parser $CDSL_DIR/top.core_desc
etiss_writer $CDSL_DIR/gen_model/top.m2isarmodel --fill-mode auto