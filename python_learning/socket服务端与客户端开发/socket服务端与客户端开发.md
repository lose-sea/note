[toc]



# socket

socket (简称 套接字) 是进程之间同通信的一个工具, 好比现实生活中的插座, 所有的家电想要工作都是基于插座进行的, 进程之间想要进行网络通信需要 socket

Socket 负责进程之间的网络数据传输, 好比数据的搬运工人

### 服务端和客户端

两个进程之间通过Socket进行相互通讯, 就必须有服务端和客户端



Socket服务端: 等待其他进程的连接, 可以接受发来的消息, 可以回复消息

Socket客户端: 主动连接服务端, 可以发送消息, 可以接受回复

![image-20260824021848455](C:\Users\Lenovo\AppData\Roaming\Typora\typora-user-images\image-20260824021848455.png)



# Socket 服务端编程

socket服务端开发主要分为以下几个步骤 : 

### 创建socket对象

```python 
import socket 
socket_server =socket.socket() 
```

### 绑定socket_server 到指定的IP和地址

```python
socket_server.bind(host, port)
```

### 服务端开始监听端口

```python
socket_server.listen(backlog)
```

> 这里的backlog 为 int 整数, 表示允许的连接数量, 超出会等待, 可以不填, 不填会自动设置一个合理值

### 接受客户端连接, 获得连接对象

```python
conn, address = socket_server.accept()
print(f"接收到客户端连接, 来自: {address}")
```

`accept()` 方法是阻塞方法, 如果没有连接, 会卡在当前这一行不向下执行 

>  accept 放回的是一个二元元组, 可以使用上述形式, 用两个变量接收二元元组 2 个元素

####  客户端返回连接之后, 通过 recv 方法, 接受客户端发送的消息

```python
while True:
    data = conn.recv(1024).decode("utf-8")

    if data == 'exit':
        break
    print("接收到发送来的数据: ", data)
```

recv 方法的返回值是字节数组, 可以通过 decode 使用 UTF-8 解码为字符串

recv 方法的传参是 buffsize, 缓冲区大小, 一般设置为 1024 

可以通过 while True 无限循环来持续和客户端进行数据交互

可以通过判定客户端发来的特殊标记, 如 exit , 来退出循环

### 通过conn (客户端当次连接对象), 调用send 方法可以回复消息

```python
conn.send("返回的消息".encode("utf-8"))
```

### conn (客户端当次连接对象)和socket_server对象调用close方法, 关闭连接

```python
conn.close() 
```



完整代码如下: 

```python
import socket

# 创建socket对象
socket_server = socket.socket()

# 绑定I地址和P端口
socket.server.bind(("localhost", 8888))

# 监听端口
socket_server.listen(1) # 表示允许的连接数量

# 等待客户端连接
# result: tuple = socket_server.accept()
# conn = result[0] # 客户端与服务端的连接对象
# address = result[1] # 客户端的地址信息
# 等价于:
conn, address = socket_server.accept()
# accept 返回的是一个二元元组 (连接对象, 地址信息)
# accept 是一个阻塞方法, 如果没有连接, 就不会向下执行
print(f"接受到信息来自: {address}")
while True:
    # 接受客户信息, 要使用客户端与服务端的本次连接对象, 而不是 socket_server对象
    data: str = conn.recv().decode("utf-8")
    # recv 接收参数缓冲区大小, 一般给 1024
    # 返回的是一个字节数组, bytes 对象, 不是字符串, 可以通过encode方法通过"utf-8"编码,将字节数组转换为字符串对象
    print("接收到的信息: ", data)

    # 输入回复消息
    msg = input().encode("utf-8")

    # 设置结束标志
    if msg == "exit":
        break

    # 发送回复消息
    conn.send(msg)

# 关闭连接
conn.close()

# 关闭客户端的通讯连接
socket_server.close()
```



# Socket 客户端编程 

socket 客户端编程主要分为以下几个步骤: 

### 创建Socket 对象

```python
import socket
socket_client = socket.socket() 
```

### 连接到服务端

```python
socket_client.connect(("localhost", 8888))
```

### 发送消息 

```python
while True:
    send_msg = input("请输入要发送的消息: ")

    # 设置停止标志
    if send_msg == "exit":
        break
    socket_client.send(send_msg.encode("utf-8"))
```

发送和传输的信息都是以字节数组的形式传输的, 以 UTF-8 编码即可

### 接收返回信息

```python
recv_msg = socket_client.recv(1024)
    
    print(recv_msg.decode("utf-8")) 
```

 recv 是阻塞式的, 即接收不到返回, 就卡在这里等待

 接收的信息需要通过 UTF-8 编码为字符串

### 关闭链接 

```python
socket_client.close()
```



具体代码如下: 

```python
import socket
socket_client = socket.socket()

socket_client.connect(("localhost", 8888))

while True:
    send_msg = input("请输入要发送的消息: ")

    # 设置停止标志
    if send_msg == "exit":
        break
    socket_client.send(send_msg.encode("utf-8"))

    recv_msg = socket_client.recv(1024)
    # recv 是阻塞式的, 即接收不到返回, 就卡在这里等待
    print(recv_msg.decode("utf-8")) # 接收的信息需要通过 UTF-8 编码为字符串

# 关闭链接
socket_client.close()
```

