1，每次新启动要参考如下cmd，其中pkill是根据情况可选的
pkill -x VoxStudio 2>/dev/null || true
./scripts/bundle.sh debug --sign && open "$PWD/.build/VoxStudio.app"


