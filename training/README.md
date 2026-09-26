# Training adapters

此目录将放置训练后端适配、配置编译、任务状态机与产物校验代码，不保存上游源码、训练数据、缓存或权重。

首个适配目标是固定版本的 `kohya-ss/sd-scripts`。适配器必须通过子进程和明确协议运行，不能把训练依赖安装进 AUTOMATIC1111 的虚拟环境。

真正的训练任务写入仓库外 `<user-data>/training/jobs/<job-id>/`。
