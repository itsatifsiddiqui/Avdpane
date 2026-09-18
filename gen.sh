#!/bin/sh
# Regenerates the Swift gRPC client from the emulator proto. Run from anywhere.
OUT="$(cd "$(dirname "$0")" && pwd)/Sources/Avdpane/Generated"
mkdir -p "$OUT"
protoc -I ~/Library/Android/sdk/emulator/lib -I /opt/homebrew/include \
  --swift_out="$OUT" --swift_opt=Visibility=Internal \
  --grpc-swift-2_out="$OUT" --grpc-swift-2_opt=Client=true,Server=false \
  emulator_controller.proto ui_controller_service.proto
