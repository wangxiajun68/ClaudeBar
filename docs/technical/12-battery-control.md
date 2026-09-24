# 电池充电控制

> ClaudeBar 技术文档 · §12
> 相关：设计文档 [产品概述](../design/01-product-overview.md) · [文件结构](../design/07-file-structure.md)

能源卡片支持 20–100% 上限（默认 80%）、充电至上限、暂停充电、接电放电至上限和恢复系统管理。阈值保存在本地；改变滑杆不会直接写入硬件，点击模式按钮或“应用上限”后才生效。退出应用恢复系统管理，下次启动默认不接管电池。

## 控制行为

- 限充：达到上限后停止充电，低于上限 2 个百分点再恢复，避免读数抖动反复启停。
- 暂停：禁止充电但保留适配器供电；低于 20% 时允许充电。
- 放电：禁止充电并断开适配器输入，降到上限后转为限充。合盖也结束主动放电；未接电源时不开始主动放电。
- 休眠：IOKit 电源通知到达时恢复原始控制值，再允许休眠。唤醒恢复限充，主动放电不自动恢复。**休眠期间不承诺保持上限。**
- 所有状态代表 SMC 控制指令已写入并回读一致；真实充电电流仍由系统、温度、电池和适配器决定，能源图继续显示传感器读数。

## 实现与权限

`Sources/batteryctl/batteryctl.c` 是独立 C 辅助进程，`--probe` 只读，`--serve` 需要 root。仅接受四种模式、20–100 阈值、请求版本号和 heartbeat；不提供任意 SMC key、路径、shell 或网络接口。

用户首次点击控制按钮时，系统管理员授权将随包签名的工具安装到 `/Library/PrivilegedHelperTools/com.claudebar.batteryctl`，root:wheel / 4755。安装采用 root 目录中的临时副本，校验 SHA-256 与代码签名后再设置权限并替换。运行前校验安装副本归属、文件类型、权限和内容与当前包一致。没有 launch daemon；应用通过私有 stdin/stdout 管道与工具通信。授权取消只显示错误，不启用控制。

辅助进程持有 `/var/run/claudebar-battery.lock` 排他锁；启动时遇到已有非零充电控制值会拒绝接管，提示先关闭其他电池工具。其他工具在运行期间重新写入不受 ClaudeBar 控制，因此不要同时启用多个限充工具。

每 2 秒读取电池并评估策略；每次写入后回读确认；状态带请求版本，界面不乐观显示成功。应用每 5 秒 heartbeat。管道 EOF、20 秒失联、无效命令、传感器异常、SIGTERM/SIGINT/SIGHUP 都进入恢复路径。部分写入失败时先恢复适配器，再恢复充电控制。恢复失败会明确提示，不能保证 SIGKILL、系统崩溃或固件故障下自动恢复。

## SMC 兼容性

优先 CHTE（4 字节；禁止充电 01 00 00 00）；否则需要 CH0B 和 CH0C（各 1 字节；禁止充电 02）。主动放电按 CHIE（08）、CH0J（01）、CH0I（01）顺序检测。恢复值来自启动时的原始状态，仅接受全零正常状态作为接管起点。所有 key 由程序固定列出，核对长度，不探写未知 key。使用项目现有 80 字节 AppleSMC 协议，并完整回传 key metadata。

机型能力只读检测成功不等于硬件写入已经验证。未检测到充电 key 时禁用全部控制；无放电 key 时仅禁用主动放电。

## 参考与来源

AlDente 当前版本已闭源。本实现为独立编写，复现其公开的限充与放电行为，没有复制其现版代码、品牌资源或 UI。

- [AlDente 官方功能与闭源说明](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring)
- [actuallymentor/battery 的公开 SMC key 与读写值](https://github.com/actuallymentor/battery/blob/main/battery.sh)，用于核对现代 macOS 的 CHTE 和适配器控制协议。

## 验证

```sh
clang -Wall -Wextra -Werror Tests/battery-control.c -framework IOKit -framework CoreFoundation -o /tmp/claudebar-battery-tests
/tmp/claudebar-battery-tests
CLAUDEBAR_SKIP_INSTALL=1 CODESIGN_IDENTITY=- bash Sources/build.sh
```

测试将生产辅助进程的 IOKit transport 替换为内存模拟，覆盖阈值范围、滞回、20% 保底、严格命令解析、无重复写入、部分写入回滚、恢复失败、缺少放电能力和休眠恢复。不会安装特权工具或修改真实 SMC。
