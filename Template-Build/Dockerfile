# [Example] 示例 Dockerfile —— 请按你的项目实际情况替换
FROM nginx:alpine

# [Modify] 复制源码到镜像中
# 模板自带的 src/ 只是一个占位页面 (为了让模板开箱即可构建成功),
# 换成你自己的源码目录即可
COPY ./src /usr/share/nginx/html

# 暴露端口 (虽然不用映射到宿主机, 但最好声明一下)
EXPOSE 80
