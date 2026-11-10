# grab-gpu

在 AWS 上用**按需（On-Demand）方式**抢 GPU 容量，抢到为止。

GPU 紧张的时候，`run-instances` 会报 `InsufficientInstanceCapacity`。
`grab-gpu.sh` 会在多个机型、多个 AZ 之间不停地申请
**ODCR（按需容量预留）**，抢到一个就留一个。容量一旦到手，
机器随便开、关、换，容量都不会丢。

[English](README.md)

## 为什么用 ODCR，不直接 run-instances？

| | run-instances | ODCR |
|---|---|---|
| 拿到的是什么 | 一台运行中的机器 | 某个 AZ 某个机型的容量，给你留着 |
| 每次重试要带 AMI / 子网 / 安全组 / 密钥 | 要 | 不要，只要机型 + AZ + 数量 |
| 机器 stop / terminate 以后 | 容量还回去 | 容量还是你的 |
| 只抢到一部分 | 用 MinCount 可以少拿 | 一次请求要么全给要么不给（脚本会减半重试） |
| 价格 | 按需价，机器运行时才收 | 按需价，**预留生效就开始收，用不用都收** |
| Savings Plans | 能用 | 能用 |

## 脚本做了什么

- 按你给的机型顺序，在每个有这个机型的 AZ 里试。
- 先申请全部剩下的数量；没容量就减半（4 → 2 → 1），空出几台就先占几台。
- 每个预留都打上 tag（`grab-gpu=<tag>`），`--status` / `--release` 能找到。
- 一轮都失败就等更久（30 秒起，最多 300 秒，带随机抖动），抢到就重置。
- 碰到配额、权限、参数错误马上停（重试也没用）。
- 可以用 SNS，抢到就发消息。

## 怎么用

需要 bash 4+ 和 AWS CLI v2，不用 Python。

```bash
# 先测：--dry-run 只检查权限和参数，不会真的创建
./grab-gpu.sh -r eu-central-1 -t g6e.12xlarge -n 2 --dry-run

# 抢 4 台：先试 g6e.12xlarge，再试 g6e.24xlarge，抢到发 SNS
./grab-gpu.sh -r eu-central-1 -t g6e.12xlarge,g6e.24xlarge -n 4 \
  -s arn:aws:sns:<region>:<account>:<topic>

# 退出登录后继续跑
nohup ./grab-gpu.sh -r eu-central-1 -t p4d.24xlarge -n 2 > grab.out 2>&1 &

./grab-gpu.sh -r eu-central-1 --status    # 看抢到了什么
./grab-gpu.sh -r eu-central-1 --release   # 全部释放，停止收费
```

参数和退出码见 [README.md](README.md)。

## 抢之前

1. **先查按需 vCPU 配额**（G and VT / P instances）。很多时候失败是配额不够，不是没货。一台 p4d.24xlarge 就是 96 vCPU。
2. **机型和 AZ 多给几个**，选择越多越容易抢到。
3. **不用就释放**。ODCR 生效后没开机器也收费。
4. 量大或长期要用，同时找 AWS account team。脚本只能抢偶尔空出来的容量。

## 测试

```bash
tests/test.sh            # 离线，用假的 aws 命令模拟没容量和配额错误
LIVE=1 tests/test.sh     # 再加一次真实的 --dry-run（需要凭证，不创建资源）
```

## License

MIT-0
