# OneFlow

OneFlow 是一个深度学习框架，旨在**易用，可扩展且高效**。使用 OneFlow，很容易做到:

- 模型编程使用与 pytorch 类似的 API

- 使用 global API 将模型扩展到 n 维并行以便于分布式执行
- 使用静态图编译器加速/部署模型

## Latest News

- Version 0.9.0 is out!
  - [Full changelog](https://github.com/Oneflow-Inc/oneflow/releases/tag/v0.9.0)

## 安装 OneFlow-DCU

### System Requirements

- Linux.

- Python 3.7, 3.8, 3.9

- (**推荐**) Upgrade pip

  ```
  python3 -m pip install --upgrade pip #--user
  ```

###  Pip 安装

可以再光合[光合开发者社区](https://developer.hpccube.com/tool/#sdk) AI 生态包中获取最新的 Oneflow-DCU Release 版本（需对应 DCU Toolkit 版本与 python 版本）

```bash
python3 -m pip install oneflow-0.9+dtk22101.git.5be579-cp39-cp39-manylinux_2_17_x86_64.manylinux2014_x86_64.whl
```

### 使用镜像

提供 oneflow 0.9，dtk-22.10.1，python 3.9 的光源镜像

```
docker pull image.sourcefind.cn:5000/dcu/admin/base/oneflow:0.9.1-centos7.6-dtk-22.10.1-py39-latest
```

### 在 DCU 平台上源码编译（DTK-22.10.1，Python3.9）

- 拉取官方 CPU 镜像

  ```
  docker pull oneflowinc/manylinux2014_x86_64_cpu:latest
  ```

- 使用官网镜像建立 docker

  ```
  docker run -it --network=host --name=oneflow_compile --privileged --device=/dev/kfd --device=/dev/dri --ipc=host --shm-size=16G  --group-add video --cap-add=SYS_PTRACE --security-opt seccomp=unconfined -u root --ulimit stack=-1:-1 --ulimit memlock=-1:-1 -v /public/home/xxx:/home oneflowinc/manylinux2014_x86_64_cpu:latest /bin/bash
  
  docker exec -it oneflow_compile /bin/bash
  ```

- 拉取 oneflow 代码

  ```
  git clone -b 0.9.1-rocm http://developer.hpccube.com/codes/aicomponent/oneflow.git
  ```

- 在[开发者社区](https://developer.hpccube.com/tool/#sdk) DCU Toolkit 中下载 DTK-22.10.1 解压至 /opt/ 路径下，并建立软链接

  ```
  cd /opt && ln -s dtk-22.10.1 rocm
  ```

- 导入环境变量以及安装必要依赖库

  ```
  export ROCM_PATH=/opt/rocm
  export HIP_PATH=${ROCM_PATH}/hip
  export CPACK_INSTLL_PREFIX=$ROCM_PATH
  export AMDGPU_TARGETS="gfx900;gfx906"
  export PATH=${ROCM_PATH}/bin:${ROCM_PATH}/llvm/bin:${ROCM_PATH}/hcc/bin:${ROCM_PATH}/hip/bin:$PATH
  export LD_LIBRARY_PATH=${ROCM_PATH}/lib:${ROCM_PATH}/lib64:$LD_LIBRARY_PATH
  export LD_LIBRARY_PATH=${ROCM_PATH}/hip/lib:${ROCM_PATH}/llvm/lib:${ROCM_PATH}/opencl/lib/x86_64:$LD_LIBRARY_PATH
  export C_INCLUDE_PATH=${ROCM_PATH}/include:${ROCM_PATH}/hip/include/hip:${ROCM_PATH}/llvm/include:/opencl/include:${C_INCLUDE_PATH}
  export CPLUS_INCLUDE_PATH=${ROCM_PATH}/include:${ROCM_PATH}/hip/include/hip:${ROCM_PATH}/llvm/include:/opencl/include:${CPLUS_INCLUDE_PATH}
  export PATH=${ROCM_PATH}/miopen/bin:${ROCM_PATH}/rocblas/bin:${ROCM_PATH}/hipsparse/bin:$PATH
  export LD_LIBRARY_PATH=${ROCM_PATH}/miopen/lib:${ROCM_PATH}/rocblas/lib:$LD_LIBRARY_PATH
  export MIOPEN_SYSTEM_DB_PATH=${ROCM_PATH}/miopen/share/miopen/db/
  export LD_LIBRARY_PATH=/usr/lib64:$LD_LIBRARY_PATH
  export LIBRARY_PATH=/usr/lib64:$LIBRARY_PATH                     
  export RCCL_PATH=$ROCM_PATH/rccl
  export NCCL_PATH=$ROCM_PATH/rccl
  export LD_LIBRARY_PATH=$RCCL_PATH/lib:$LD_LIBRARY_PATH
  
  export MIOPEN_FIND_MODE=3
  export HSA_FORCE_FINE_GRAIN_PCIE=1
  export MIOPEN_COMPILE_PARALLEL_LEVEL=1
  
  source /opt/rh/devtoolset-7/enable
  
  export PV=39
  ln -s /opt/python/cp${PV}-cp${PV}/bin/python3 /usr/bin/python3
  ln -s /opt/python/cp${PV}-cp${PV}/bin/pip3 /usr/bin/pip3
  
  yum install -y numactl libffi* openblas openblas-devel libibverbs-devel
  cd oneflow && pip3 install -r dev-requirements.txt -i http://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com
  ```

- cmake && make

  ```
  cd oneflow && mkdir build && cmake .. -DBUILD_CUDA=OFF -DBUILD_ROCM=ON -DONEFLOW=ON -DUSE_CLANG_FORMAT=OFF -DCMAKE_BUILD_TYPE=Release -DTHIRD_PARTY=ON -DTREAT_WARNINGS_AS_ERRORS=OFF -DTHIRD_PARTY_MIRROR=aliyun -DBUILD_HWLOC=OFF -DCMAKE_C_COMPILER=${ROCM_PATH}/llvm/bin/clang -DCMAKE_CXX_COMPILER=${ROCM_PATH}/llvm/bin/clang++ -DBUILD_TESTING=ON -DBUILD_RDMA=ON -DBUILD_PROFILER=ON
  
  make -j32
  ```

- 验证安装

  ```
  cd build && source source.sh    # 将oneflow导入PYTHONPATH
  python3 -c “import oneflow”
  ```

### Advanced features

- [OneFlow-XRT](https://github.com/Oneflow-Inc/oneflow-xrt): An extension for OneFlow to target third-party compiler, such as XLA, TensorRT and OpenVINO etc.

## Getting Started

- Please refer to [QUICKSTART](https://docs.oneflow.org/en/master/basics/01_quickstart.html)
- 中文版请参见 [快速上手](https://docs.oneflow.org/master/basics/01_quickstart.html)

## Documentation

- [API Reference](https://oneflow.readthedocs.io/en/master/)
- [Usage & Design Docs](http://docs.oneflow.org/)
- [System Design](https://docs.oneflow.org/en/v0.4.0/basics_topics/essentials_of_oneflow.html)

## Model Zoo and Benchmark

- [Libai(Toolbox for Parallel Training Large-Scale Transformer Models)](https://github.com/Oneflow-Inc/libai)
  - [BERT-large](https://libai.readthedocs.io/en/latest/tutorials/get_started/quick_run.html)
  
  - [GPT](https://libai.readthedocs.io/en/latest/modules/libai.models.html#id5)
  
    使用LiBai的GPT2，DCU与A800的精度对比曲线如下：
  
    ![a68d1d3151e39b4c80d337223678862](C:\Users\Administrator\AppData\Local\Temp\WeChat Files\a68d1d3151e39b4c80d337223678862.jpg)
  
  - [T5](https://libai.readthedocs.io/en/latest/modules/libai.models.html#id4)
  
  - [VisionTransformer](https://libai.readthedocs.io/en/latest/modules/libai.models.html#id1)
  
  - [SwinTransformer](https://libai.readthedocs.io/en/latest/modules/libai.models.html#id2)
  
- [FlowVision(Toolbox for Computer Vision Datasets, SOTA Models and Utils)](https://github.com/Oneflow-Inc/vision)

- [OneFlow-Models(Examples of How to Implement Models in Various Fields with OneFlow)](https://github.com/Oneflow-Inc/models)
  - [ResNet-50](https://github.com/Oneflow-Inc/models/tree/main/Vision/classification/image/resnet50)
  - [Wide&Deep](https://github.com/Oneflow-Inc/models/tree/main/RecommenderSystems/wide_and_deep)
  
- [OneFlow-Benchmark(Outdated)](https://github.com/Oneflow-Inc/OneFlow-Benchmark)

## Communication

- [GitHub issues](https://github.com/Oneflow-Inc/oneflow/issues): any install, bug, feature issues.
- [www.oneflow.org](http://www.oneflow.org): brand related information.

- ### 中文

  - QQ 群: 331883
  - 微信号（加好友入交流群）: OneFlowXZS
  - [知乎](https://www.zhihu.com/org/oneflow-17)

- ### International
  - [Discord](https://discord.gg/4kpjGA5bZY)
  - [Twitter](https://twitter.com/OneFlowNews)
  - [LinkedIn](https://www.linkedin.com/company/oneflow-inc)
  - [Medium](https://oneflow2020.medium.com)

## The Team

OneFlow was originally developed by [OneFlow Inc](http://www.oneflow.org) and [Zhejiang Lab](http://www.zhejianglab.com/).

## License

[Apache License 2.0](LICENSE)
