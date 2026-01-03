# 内存四区以及new操作符

# 内存分区模型

c++程序在执行时,将内存大方向划分为4个区域

- 代码区:存放函数体的二进制代码,由操作系统进行管理
- 全局区: 存放全局变量和静态变量以及常量
- 栈区: 由编译器自动分配释放,存放函数的参数值,局部变量等
- 堆区:由程序员分配和释放,若程序员不释放,程序结束是由操作系统回收

内存四区的意义:

不同区域存放不同的数据,赋予不同的生命周期,给我们更大的灵活编程

**程序运行前:**

在程序运行前,生成了exe可执行程序,未执行该程序前分为两个区域:

# **代码区**:

存放CPU执行的机器指令–(代码)

代码区是**共享**的,共享的目的是对于频繁被执行的程序,只需要在内存中有一份代码即可

代码区是**只读**的,使其只读的原因是防止程序意外地修改了它的指令

**代码区的特点是共享和只读**

# **全局区**

全局变量和静态变量存放于此

全局区还包含了常量区,字符串常量和其他常量也存放于此

该区域的数据在程序结束后有操作系统释放

全局区存放的数据类型:

全局变量

静态变量–在普通变量前面加上**static**修饰,就属于静态变量

常量:

- 字符串常量
- const 修饰的全局变量

注意:**const修饰的局部变量仍存储在栈区,不存储在全局区**

不在全局区的数据:

局部变量

const修饰的局部变量–局部常量

# 栈区

由编译器自动分配释放,存放函数的参数值,局部变量等

注意:不要返回局部变量的地址,栈区开辟的数据由编译器自动释放

在 C++ 中，局部变量存储在栈区，函数执行结束后会被释放。如果返回局部变量的地址，后续使用该地址会导致未定义行为。

- 如果需要返回变量的地址，可将变量定义为静态变量（`static int a;`），静态变量存储在全局数据区，函数结束后不会被释放。
- 也可通过动态内存分配（如`new`）在堆区创建变量，使用后需记得用`delete`释放内存。

例如:

```c
#include <iostream>
using namespace std;
int* func() {
    int a = 10;
    return &a;
}
int main() {
    int* p = func();
    cout << *p << endl;
    return 0;
}

```

==无法正常输出==

```c
#include <iostream>
using namespace std;
int* func() {
    static int a = 10;
    return &a;
}
int main() {
    int* p = func();
    cout << *p << endl;
    return 0;
}

```

可以正常输出

```c
10

```

形参数据也会放在栈区

# 堆区

由程序员分配释放，若程序员不释放，程序结束时由系统回收

在C++中主要利用new在堆区开辟内存

```c
#include<iostream>
using namespace std;
int* func() {
    // 利用new关键字，可以将数据开辟到堆区
    int* p = new int(4);
    return p;
}
int main() {
   int* p = func();
    cout << *p << endl;
    cout << *p << endl;
    cout << *p << endl;
    return 0;
}

```

利用new关键字，可以将数据开辟到堆区

指针 本质也是局部变量，放在栈上，指针保存的数据是放在堆区

用new关键字创建堆区的数据，并不是返回数据本身，而是返回这个堆区数据的地址

堆区： 堆区数据由程序员管理开辟和释放

堆区数据利用new关键字进行开辟内存

# new操作符

c++中利用new操作符在堆区开辟数据

堆区开辟的数据，由程序员手动开辟，手动释放， 释放利用操作符==delete==

> 利用new创建的数据，会返回该数据对应的类型的指针
> 

```c
#include<iostream>
using namespace std;
int* func() {
    int* p = new int(10);
    return p;
}
void test1() {
    int* p  = func();
    cout << *p << endl;
    cout << *p << endl;
    cout << *p << endl;
    delete p;
    cout << *p << endl;
}
int main() {
    test1();
    return 0;
}

```

使用delete释放内存

输出

```c
10
10
10
16609040

```

在最后一次打印前释放了内存,打印了乱码

在堆区创建数组

```c
void test2() {
    //  在堆区创建一个10整型的数组
    int* arr = new int[10];
    for (int i = 0; i < 10; i++) {
        arr[i] = i + 100;
    }
    for (int i = 0; i < 10; i++) {
        cout << arr[i] << endl;
    }
}

```

释放堆区数组

释放数组的时候,要加上[]才可以

例如:

`delete[] arr;`

```c
void test2() {
    //  在堆区创建一个10整型的数组
    int* arr = new int[10];
    for (int i = 0; i < 10; i++) {
        arr[i] = i + 100;
    }
    for (int i = 0; i < 10; i++) {
        cout << arr[i] << endl;
    }
    delete[] arr;
}

```