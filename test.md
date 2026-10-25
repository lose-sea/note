# 26级3g移动应用开发一二面题解

[toc]





## 一面题解

### 1.**Ciallo～(∠・ω< )⌒☆ 3G !**

```c
#include <stdio.h>
#include <string.h>
int main() {
	int x = 0;
	char b = 'E';
	int a = (b++, ++b == 70 ? 2 : 3);
	char c[] = "c";
	int d = sizeof(b) * sizeof(c) * 1024 - strlen("Hello, 3G! Happy 2026!");
	if (x = 2026) {
		printf("Ciallo～ %d%c %d!!!\n", a, b, d);
	}
	return 0;
}
```

**1.初始化b的值**

`char b = 'E';`记录b的ASCII为69；

**2.三目运算符**

`,` 运算符先计算b++（69+1）；

接下来++b（前置自增）（70+1）为G，三目运算符（假）取3，结果a==3；

**3.计算d**

` sizeof(b) * sizeof(c) * 1024`

计算内存大小，sizeof(b)为1；sizeof(c)作为数组（c+\0）大小为2，`strlen("Hello, 3G! Happy 2026!")`长度为22，最终为2048-22=2026；

**4.依次打印**

`Ciallo～ %d%c %d!!!`

结果为Ciallo～ 3G 2026！！！

### **2. Bit 状态机**

*(这题当时看着真的很吓人)*

```c
#include <stdio.h>
#define A 0x01
#define B 0x02
#define C 0x04
#define D 0x08
int check(int x, int mask) {
	return (x & mask) == mask;
}
int main() {
	int x = 0x0D;
	x ^= C;
	if (check(x, A | C) && check(x, D)) {
		printf("A, x = 0x%X\n", x);
	}else if (check(x, B) || check(x, A)) {
		printf("B, x = 0x%X\n", x);
	}
	else {
		printf("C, x = 0x%X\n", x);
	}
	return 0;
}
```



==与掩码相关==

*必须知道的*

1. *&均为1则取1；*
2. *|均为0则取0；*
3. *^相同则取0，不同则取1，（找不同）；*

**1.ABCD**

依次为0001；0010；0100；1000；

**2.X的值**

`int x = 0x0D;	x ^= C;`x初始为16进制，转换后为1101；

^=后X为1001；

**3.条件一**

A|C，结果为0101；

0101与1001取&后与原来不相等，整式为假；

**3.条件二**

X与B取&后为0000，不等，为假；

X与A取&后为0001，一致，为真；

**4.进入二打印**

B，x=0x9；

### **3. xy，我好像在哪见过你**

```c
#include <stdio.h>
int x = 10;
static int y = 20;
void test(int x) {
	static int y = 100;
	printf("A: x = %d, y = %d\n", x, y);
	x++;
	y++;
}
void foo(void) {
	int x = 30;
	printf("B: x = %d, y = %d\n", x, y);
	test(x);
	printf("C: x = %d, y = %d\n", x, y);
}
int main(void) {
	int x = 40;
	printf("D: x = %d, y = %d\n", x, y);
	foo();
	printf("E: x = %d, y = %d\n", ++x, y);
}
```



*so easy*

**1.定义**

全局x = 10，静态y = 20；

**2.main**

声明局部x = 40；

打印D：X=40，y=20；

**3.foo**

声明局部x = 30；

打印：B：X=30，y=20；

**4.text**

声明局部y = 100；

打印：A：X=30，y=100；

x与y后置自增；

**5.回到foo**

声明局部x = 30；

打印：C：X=30，y=20；

**5.回到main**

声明局部x = 40；

打印：E：X=41，y=20；

### **4. 代码界的照骗**

```c
#include <stdio.h>
int main() {
	float a = 0.1f;
	double b = 0.1;
	double c = a;
	printf("%zu %zu\n", sizeof(a), sizeof(b));
	printf("%.20f\n", a);
	printf("%.20f\n", b);
	printf("%d %d %d\n", a == b, c == b, c == a);
	return 0;
}
```



*最简单的一道*

**1.定义精度**

a为单精度（四个字节），b为双精度（八个字节）；

打印4 8；

**2.直接打印a**

打印0.10000000131452166666

==从第八位开始我是胡乱编的==，在计算机中显示的是乱码

**3.直接打印b**

打印0.10000000000000000131

==同理==

**4.检验是否相等**

结果为0 0 1；

a与b   a与b精度不同 后面数字不同 为0；

c与b   c即为a的值 后面数字不同 为0；

c与a c即为a的值，本质一样为 1；

### **5. 每个 i、j 心中都有一处属于自己的 if-else**

```c
#include <stdio.h>
int main() {
	int arr[] = { 1, 2, 3 };
	int* p = arr;

	int i = 0, j = 0;
	if ((i++ && p[1]++) || (++i && *p++)) {
		j = j >> 2;
		printf("if branch: i=%d, j=%d, *p=%d\n", i, j, *p);
	} else {
		i = i << 2;
		j = *p + arr[1];
		printf("else branch: i=%d, j=%d, p-arr=%d\n", i, j, (int)(p - arr));
	}
	return 0;
}
```

*此题为位运算*

**1.if`(i++ && p[1]++)`**

i后置自增，初始为0，为假；

**2.if`(++i && *p++)`**

i前置自增 i为2，为真；

*p后置自增，指向1，为真；

**3.进入if条件**

j=0，位运算二进制向后移动两位，还是0；

**4.最终打印**

`if branch: i=2, j=0, *p=2`

### **6. 谁动了我的变量？**

```C
#include <stdio.h>
void test(int type) {
	static int count = 0;
	int value = 10;
	count++;
	value++;
	switch (type) {
	case 1:
		value += 10;
		printf("case1: count = %d, value = %d\n", count, value);
	case 2: {
		int value = 50;
		count += 2;
		printf("case2: count = %d, value = %d\n", count, value);
		break;
	}
	case 3:
		count += 3;
		value += 30;
		printf("case3: count = %d, value = %d\n", count, value);
		break;
	default:
		count += 4;
		printf("default: count = %d, value = %d\n", count, value);
	}
}
int main() {
	test(1);
	test(2);
	test(3);
	test(1);
	return 0;
}
```

**1.第一次调用1**

定义静态变量 count=10，普通局部value=10；

count与value自增变为1 11；

case 1：value+=10；

打印 count = 1, value = 21；

case 2：定义局部变量value=50，同时count+=2；

打印 count = 3, value = 50；

**2.第二次调用2**

count与value自增变为4 11；

case 2：定义局部变量value=50，同时count+=2；

打印 count = 6, value = 50；

**3.第三次调用3**

count与value自增变为7 11；

case 3:count+=3，value+=30；

打印 count = 10, value = 41；

**4.第四次调用4**

count与value自增变为11 11；

case 1：value+=10；

打印 count =11 , value = 21；

case 2：定义局部变量value=50，同时count+=2；

打印 count = 13, value = 50；

### **7. 欧几里得也会敲代码？？？**

```C
#include <stdio.h>
int recursion(int a, int b) {
	if (b == 0) {
		printf("->%d ", a);
		return a;
	}
	printf("(%d,%d) ", a, b);
	int x = recursion(b, a % b);
	printf("[%d] ", a);
	return x;
}
int main() {
	printf("answer = %d\n", recursion(48, 18));
	return 0;
}
```

*此题即为辗转相除法*

**1.第一层递归**

代入48 18；

打印(48,18)

` recursion(b, a % b)`为recursion(18,12)；

**2.第二层递归**

打印(18,12)

` recursion(b, a % b)`为recursion(12,6)；

**3.第三层递归**

打印(12,6)

` recursion(b, a % b)`为recursion(6,0)；

**4.第四层进入if，递归回溯**

依次打印 -> 6 [12]  [18]  [48] 

**5.回到主函数**

打印 answer = 6

### **8. 二维数组的“方寸之间”**

```c
#include <stdio.h>
int main() {
	int a[2][3] = { {1,2,3},
	{4,5,6} };
	int* p = a[0];
	int (*q)[3] = a;

	printf("%d\n", *(p + 3) + *(*(q + 1) + 1));
	printf("%d\n", *(a[1] - 1) + *(a[0] + 4));
	printf("%d\n", (int)((int*)(a + 1) - (int*)(a + 0)));
	printf("%zu\n", sizeof(a + 1) + sizeof(*a));
	printf("%d\n", (p + 2)[1] - (*(q + 1))[-1]);
	return 0;
}
```

**第一行：`printf("%d\n", \*(p + 3) + \*(\*(q + 1) + 1))`**

*p向后移三位指向‘4’；

*q指向q[1]\[1],为5；

最终为4+5=9；

**第二行：`printf("%d\n", *(a[1] - 1) + *(a[0] + 4))`**

a[1]从第二行后退一个，为3；

a[1]从第一行前进四个，为5；

最终为3+5=8；

**第三行：`printf("%d\n", (int)((int\*)(a + 1) - (int\*)(a + 0)));`**

强制转换为int*类型，相减即为相差元素个数；

a+1跳跃一行，两者相减即为3；

最终打印3；

**第四行：`printf("%zu\n", sizeof(a + 1) + sizeof(\*a));`**

a为数组名，+1进行偏移结果就是一个指针 算8；

*a退化成第一行，占据一行4\*3=12;

打印12+8=20；

**第五行：`printf("%d\n", (p + 2)[1] - (\*q + 1)[-1]);`**

p+2先将p向后移两位，再[1],向后再移一位，指向4；

q指向第二行，再向前移一位，指向3；

打印4-3=1；

### **9. 不集齐五组怎么召唤神龙？**

```c
#include <stdio.h>
typedef void (*Lab)(const char* group);
void iOS(const char* group) {
	printf("Language of %s is Swift", group);
}
void Android(const char* group) {
	printf("Language of %s is Kotlin", group);
}
void Web(const char* group) {
	printf("Language of %s is JavaScript", group);
}
void print_3G(Lab Lab3G, const char* group) {
	Lab3G(group);
}
int main() {
      Lab groups[] = { iOS, Android, Web };
	
		print_3G(groups[1], "Android");
	return 0;
}
```

*这道题，听说是一位非常厉害的学长～出的（真的难啊）*

1.`typedef void (*Lab)(const char* group);`	

定义了一个类型为函数指针的Lab，可以理解Lab类似为int char

2.`void print_3G(Lab Lab3G, const char* group)`

此函数接收Lab类型的指针，和一串字符

3.`  Lab groups[] = { iOS, Android, Web };`

这里定义了一个函数指针数组

4.`print_3G(groups[1], "Android");`

接下来将Android与"Android"传入函数

执行Android("Android")

5.打印执行

`Language of Android is Kotlin`





### **10. 只管复制粘贴，不包售后**

```C
#include <stdio.h>
#define N 10
#define HALF N / 2
#define SQUARE(x) ((x) * (x))
#define AVG(a, b) ((a) + (b)) / 2
#define INC(x) ((x)++)
int main() {
	int a = 3, b = 5, c = 0;
	printf("1: %d\n", HALF);
	printf("2: %d\n", SQUARE(HALF));
	c = AVG(a, b);
	printf("3: %d\n", c);
	c = AVG(a, b) * 2;
	printf("4: %d\n", c);
	c = AVG(a + 1, b + 3);
	printf("5: %d\n", c);
	c = AVG(a++, b--);
	printf("6: c=%d, a=%d, b=%d\n", c, a, b);
	c = INC(a) + INC(b);
	printf("7: c=%d, a=%d, b=%d\n", c, a, b);
	return 0;
}
```

*这也算是非常简单的一道题*

**第12步**

1:直接打印N/2=5；

2:直接打印5*5=25；

**第3步**

命令从c=AVG(a, b)；

3.计算完c=4；

**第4步**

4.第三步直接*2，结果是8；

**第5步**

5.（4+8）/2，结果是6；

**第6步**

a与b分别是后置自增自减，先计算c=4；

6.结果c= 4, a= 4, b= 4；

**第7步**

后置自增，计算c为8；

7.打印c= 8, a= 5, b= 5；



**### 11. 谁动了我的字节？**

```C
#include <stdio.h>
#pragma pack(4)
union Data {
	int num;
	char buf[8];
};
struct Inner {
	short a;
	union Data data;
};
struct Outer {
	char flag;
	struct Inner in;
	int* p;
};
int main() {
	printf("union Data: %zu\n", sizeof(union Data));
	printf("struct Inner: %zu\n", sizeof(struct Inner));
	printf("struct Outer: %zu\n", sizeof(struct Outer));
	printf("int* : %zu\n", sizeof(int*));
	return 0;
}
```

**1 . `printf("union Data: %zu\n", sizeof(union Data));`**

联合体共享内存，因而是最大的成员大小8；

**2.`printf("struct Inner: %zu\n", sizeof(struct Inner));`**

short占据两个字节，受限与四对齐，`union Data data`偏移量为二；

总共占据12

**3.`printf("struct Outer: %zu\n", sizeof(struct Outer))`**

char占据1个字节，struct偏移4，指针占据8；

总计24；

4.`printf("int* : %zu\n", sizeof(int*));`

int*指针类型占据8个字节

### **12. 白鼠试毒问题**

**有 1000 瓶药水，其中只有 1 瓶是毒药。毒药发作时间是 24 小时。 问题： 你只有 10 只小白鼠，如何用最少的**

**小白鼠，在 24 小时后找出哪瓶是毒药？（提示：不需要写代码，说思路即可）**

*这道题有且仅有一种方法，即利用二进制进行编排，我们可以将十只老鼠排成一排，把每一瓶药水按二进制从小到大命名，如遇到1000101000，就将药水喂给第1/5/9只老鼠   最终老鼠死亡的对应的编码即为，毒药对应的编码。*





### **13. 实现你自己的 qsort**

你知道多少种排序算法？请你在现场用代码实现一种排序并将它封装为函数，并说明它的原理

冒泡排序，选择排序，插入排序，希尔排序，快速排序，归并排序；

这里展示冒泡，和快排

***冒泡***

```c
#include<stdio.h>

void maopao(int arr[], int n) {
	int j, i, temp;
	for (i = 0; i < n-1; i++) {
		for (j = 0; j < n - i - 1; j++) {
			if (arr[j + 1] > arr[j]) {
				temp = arr[j];
				arr[j] = arr[j + 1];
				arr[j + 1] = temp;
			}
		}
	}
}
int main() {
  int count;
	int i = 0;
	int arr[100];
	int x;
	scanf_s("%d", &count);
	for (i = 0; i < count; i++) {
		scanf_s("%d", &arr[i]);
	}
	maopao(arr, count);

	for (i = 0; i < count; i++) {
		printf("%d", arr[i]);
		}
	return 0;
}
```

***快速排序***

```   c
#include<stdio.h>

void quick(int a[], int left, int right) {
  if(left >= right) return;  
  int i = left, j = right; 
  int pivot = a[left]; 
  while (i < j) {
    while (i < j && a[j] >= pivot) j--; 
    a[i] = a[j];
    while(i < j && a[i] <= pivot) i++; 
    a[j] = a[i]; 
  }
      
a[i] = pivot; 
quick (a, left, i - 1);
quick (a, i + 1, right);
} 
int main() {
    int arr[] = {10,7,8,9,1,5}; 
    int n = sizeof(arr)/sizeof(arr[0]); 
    quick(arr,0,n-1); 
    for(int i = 0; i < n; i++) {
        printf("%d   ",arr[i]);  
    }
    return 0; 
}
```







## 二面题解

## [A - 九九乘方表](https://vjudge.net/problem/洛谷-B3700)

 [洛谷 - B3700 ](https://vjudge.net/problem/洛谷-B3700/origin)

**九九乘法表的前三行为：**

```
1 * 1 = 1`
`2 * 1 = 2 2 * 2 = 4`
`3 * 1 = 3 3 * 2 = 6 3 * 3 = 9
```

**类似的，我们可以定义出九九乘方表，其前三行为：**

```
1 ^ 1 = 1`
`2 ^ 1 = 2 2 ^ 2 = 4`
`3 ^ 1 = 3 3 ^ 2 = 9 3 ^ 3 = 27
```

**`a ^ b` 的含义为 ab*a**b*，也就是 b*b* 个 a*a* 相乘。**

==注意== *这是乘方表，不是乘法表*

**这是答案**



```c
#include<stdio.h>

int main() {
	int n; 
	scanf("%d", &n); 
	for (int i = 1; i <= n; i++) {
		for (int j = 1; j <= i; j++) {
			int x = 1; 
			for (int t = 0; t < j; t++) {
				x *= i;  
			}
			printf("%d ^ %d = %d ", i, j, x);
		} printf("\n"); 
	}


	return 0;
}
```



此题可以嵌套两个for循环进行打印，再进行乘方时，可以借用库函式`pow（，）`，也可以利用for循环，还是很简单的；

## [B - 求一元二次方程](https://vjudge.net/problem/洛谷-B2053)

[洛谷 - B2053 ](https://vjudge.net/problem/洛谷-B2053/origin)

利用公式 :



```C
#include<stdio.h>
#include<math.h>
#include<string.h>
int main() {
	double a, b, c,mm;
	scanf("%lf%lf%lf", &a, &b, &c);
	double x1, x2;
if ((b * b - 4 * a * c) < 0) {
	printf("No answer!"); 
    return 0; 
}
x1 = (-b + sqrt(b * b - 4 * a * c)) / (2 * a); 
x2 = (-b - sqrt(b * b - 4 * a * c)) / (2 * a); 
 if ((b * b - 4 * a * c) < 1e-6) {

	printf("x1=x2=%.5f", x1); 
}
	else if ((b * b - 4 * a * c) > 0) {
		if (x1 < x2) {
			printf("x1=%.5f; ", x1); 
			printf("x2=%.5f", x2); 
		} else if (x2 < x1) {
             printf("x1=%.5f; ", x2); 
			printf("x2=%.5f", x1); 
		}
	}

return 0;
}
```

这道题看起来简单，实际上存在一些容易忽略的漏洞；

*验证 Δ==0是，不可直接等于零，比较危险应等于1e-6，浮点数等于0，非常容易报错；*

大体方法就是通过数学方法德尔塔验证与零的关系，分别判断两解，一解，和无解的情况，再分别输出对应的情况。

## [C - 最大公约数](https://vjudge.net/problem/洛谷-B4025)

 [洛谷 - B4025 ](https://vjudge.net/problem/洛谷-B4025/origin)

定义两个正整数的最大公约数 gcd⁡(a,b)gcd(*a*,*b*) 为最大的正整数 d*d*，使得 d*d* 可以同时整除 a*a* 和 b*b*。

例如，gcd⁡(9,12)=3gcd(9,12)=3，因为 9÷39÷3 和 12÷312÷3 的余数是 00，而无法找到一个比 33 更大的正整数满足要求。

现在给定两个正整数 a,b*a*,*b*，要求出 gcd⁡(a,b)gcd(*a*,*b*)。



```c
#include<stdio.h>
#include<math.h>
int gcd (int a, int b) {
	if (b == 0) {
		return a; 
	} else {
		return gcd(b, a % b); 
	}
}
int main() {
	int a, b;
	scanf("%d%d", &a, &b); 
	int x = gcd(a, b); 
	printf("%d", x); 
	return 0;
}
```

此题考察最基础的递归，输入不同的数，利用递归取余，一层一层对两个数取余，直到取余为‘0’时，对应的数，即为最大公约数。

还是非常简单的；



## [D - 车厢重组](https://vjudge.net/problem/洛谷-P1116)

 [洛谷 - P1116 ](https://vjudge.net/problem/洛谷-P1116/origin)

在一个旧式的火车站旁边有一座桥，其桥面可以绕河中心的桥墩水平旋转。一个车站的职工发现桥的长度最多能容纳两节车厢，如果将桥旋转 180180 度，则可以把相邻两节车厢的位置交换，用这种方法可以重新排列车厢的顺序。于是他就负责用这座桥将进站的车厢按车厢号从小到大排列。他退休后，火车站决定将这一工作自动化，其中一项重要的工作是编一个程序，输入初始的车厢顺序，计算最少用多少步就能将车厢排序。



```c
#include<stdio.h>
int main() {
	int n = 0;
	scanf("%d", &n);
	int arr[1005];
	for (int i = 0; i < n; i++) {
		scanf("%d", &arr[i]); 
	}
	int count = 0; 
	int j = 0; 
	for (int i = 0; i < n; i++) {
		for ( j=0; j < n - i - 1 ; j++) {
			int temp;
			if (arr[j] > arr[j + 1]) {
				temp = arr[j];
				arr[j] = arr[j + 1]; 
				arr[j + 1] = temp;  
				count++; 
			}
		}
	}
		printf("%d", count); 
	return 0;
}
```

这题看着唬人，实际非常简单，就是==冒泡排序==，加上一个变量调换顺序即可

分两层利用for循环，每次将最大的数字放到末尾，每调换一次两数的顺序，count对应就+1；

结果就是count对应的值；

## [E - 最厉害的学生](https://vjudge.net/problem/洛谷-P5740)

 [洛谷 - P5740 ](https://vjudge.net/problem/洛谷-P5740/origin)

现有 N*N* 名同学参加了期末考试，并且获得了每名同学的信息：姓名（不超过 88 个字符的仅有英文小写字母的字符串）、语文、数学、英语成绩（均为不超过 150150 的自然数）。总分最高的学生就是最厉害的，请输出最厉害的学生各项信息（姓名、各科成绩）。如果有多个总分相同的学生，输出靠前的那位。

```c
#include<stdio.h>
#include<stdlib.h>
struct student {
	char arr[10];
	int ch, ma, en;
};
int main() {
	int n; 
	char arr[1005][10];
	scanf("%d", &n);
	struct student s[1005];
	int max = 0; 
	int x = 0; 
	for (int i = 0; i < n; i++) {
		scanf("%s%d%d%d", arr[i], &s[i].ch, &s[i].ma, &s[i].en);
	}
	for (int i = 0; i < n; i++) {
		if ((s[i].ch + s[i].ma + s[i].en) > max) {
			max = (s[i].ch + s[i].ma + s[i].en); 
			x = i; 
		}
	}
	printf("%s %d %d %d", arr[x], s[x].ch, s[x].ma, s[x].en);
	return 0;
}
```

此题考查最简单的==结构体数组==，可定义一个`struct stu`来记录学生信息，对于学生姓名可以借助==二维字符数组==，逐个命名，最后利用for循环，找出最大的那个`stu[]`；

## [F - 插火把](https://vjudge.net/problem/洛谷-P1789)

 [洛谷 - P1789 ](https://vjudge.net/problem/洛谷-P1789/origin)

话说有一天，linyorson 在“我的世界”中开了一个 n×n*n*×*n* 的方阵。现在他有 m*m* 个火把和 k*k* 个萤石，分别放在 (x1,y1)∼(xm,ym)(*x*1,*y*1)∼(*x**m*,*y**m*) 和 (o1,p1)∼(ok,pk)(*o*1,*p*1)∼(*o**k*,*p**k*) 的位置。已知没有光并且没放东西的地方会生成怪物，请问在这个方阵中有几个点会生成怪物？

**注意，在本题中火把与萤石的照明范围与原版 Minecraft（我的世界）不尽相同，请以本题中的描述为准。**

火把的照亮范围是：

| 暗     | 暗     | 光       | 暗     | 暗     |
| ------ | ------ | -------- | ------ | ------ |
| **暗** | **光** | **光**   | **光** | **暗** |
| **光** | **光** | **火把** | **光** | **光** |
| **暗** | **光** | **光**   | **光** | **暗** |
| **暗** | **暗** | **光**   | **暗** | **暗** |

萤石是：

| **光** | **光** | **光**   | **光** | **光** |
| ------ | ------ | -------- | ------ | ------ |
| **光** | **光** | **光**   | **光** | **光** |
| **光** | **光** | **萤石** | **光** | **光** |
| **光** | **光** | **光**   | **光** | **光** |
| **光** | **光** | **光**   | **光** | **光** |



```C
#include<stdio.h
#include <stdlib.h>
int main() {
	int n, m, k;
	int x, y,dx,dy;
	scanf("%d%d%d", &n, &m, &k);
	int arr[105][105] = { 0 };
	for (int i = 1; i <= m; i++) {
		scanf("%d%d", &x, &y); 
		for (dx = -2; dx <= 2; dx++) {
			for (dy = -2; dy <= 2; dy++) {
				if (abs(dx) + abs(dy) <= 2) {
					int nx = x + dx;  
					int ny = y + dy; 
					if (nx <= n && ny <= n && nx >= 1 && ny >= 1)
					arr[nx][ny] = 1; 
				}
			}
		}
	}
	for (int i = 1; i <= k; i++) {
		scanf("%d%d", &x, &y);
		for (dx = -2; dx <= 2; dx++) {
			for (dy = -2; dy <= 2; dy++) {
				
				int nx = x + dx;  
				int ny = y + dy; 
				if (nx <= n && ny <= n && nx >= 1 && ny >= 1)
				arr[nx][ny] = 1; 
			}
		}
	}
	int count = 0; 
	for (int i = 1; i <= n; i++) {
		for (int j = 1; j <= n; j++) {
			if (arr[i][j] == 0) count++; 
		}
	}
	printf("%d", count); 
	return 0; 
}
```



*这应该算是最难的一道了*     *看到题吓哭了*

对于特定的==火把==我们可以这样`abs(dx) + abs(dy) <= 2`利用绝对值就可以巧妙的描绘出火把照亮的范围，就像图中展示的，辐射状照亮范围；

==萤石==就简单了（直接框定一个5*5的范围即可）；

最后

再进行一遍循环寻找’0‘即可；

## [G - 回文质数 Prime Palindromes](https://vjudge.net/problem/洛谷-P1217)

 [洛谷 - P1217 ](https://vjudge.net/problem/洛谷-P1217/origin)

因为 151151 既是一个质数又是一个回文数（从左到右和从右到左是看一样的），所以 151151 是回文质数。

写一个程序来找出范围 [a,b](5≤a<b≤100,000,000)[*a*,*b*](5≤*a*<*b*≤100,000,000)（一亿）间的所有回文质数。

```C
#include<stdio.h>
int isPrime(int x) {
    if (x < 2) {
        return 0;
    }
    if (x == 2) {
        return 1;
    }
    for (int i = 2; i * i <= x; i += 1) {
        if (x % i == 0) {
            return 0;
        }
    }
    return 1;
}
int isPalin(int x) {
    int old = x; 
    int rev = 0; 
    while (x > 0) {
        int num = x % 10; 
        rev = rev * 10 + num; 
        x = x / 10; 
    }
    if (rev == old) {
        return 1; 
    } else {
        return 0; 
    } 
}
int main() {
    int a, b;
    scanf("%d %d", &a, &b);
    for (int i = a; i <= b; i++) {
        if (isPalin(i) && isPrime(i)) {
            printf("%d\n", i); 
        }
    }
    return 0;
}
```

*本题有几个容易报错的点*  ==注意运算时间==（要先筛回文，再找质数）

素数比较简单，这里讲讲怎么筛回文；

先复制一个数字命名为`old`，接下来将数字通过对10取余再除10，再将余数*10翻转定义为`new`，接下来检验`new`与`old`

是否相等即可判断出原数是否为回文数；

## [H - 进制转换](https://vjudge.net/problem/洛谷-P1143)

 [洛谷 - P1143 ](https://vjudge.net/problem/洛谷-P1143/origin)

请你编一程序实现两种不同进制之间的数据转换

```C
#include<stdio.h>
#include<string.h>
int charNum(char c) {
	if (c >= '0' && c <= '9')return c - '0';
	else return c - 'A' + 10;
}
char numChar(int  x) {
	if (x >= 0 && x <= 9)return x + '0'; 
	else if (x >= 10)return x - 10 + 'A'; 
}
int main() {
	int n, m; 
	char s[20];
	scanf("%d", &n);
	scanf("%s", s);
	scanf("%d", &m);
	long long ten = 0;
	int len = strlen(s);
	for (int i = 0; i < len; i++) {
		ten = ten * 10 + charNum(s[i]); 
	}
	char ans[20]; 
	int p = 0; 
	if (ten == 0) {
		ans[p++] = '0'; 
	}
	while (ten > 0) {
		int rem = ten % m;
		ans[p++] = numChar(rem);
		ten = ten / m;
	}
	for (int i = p - 1; i >= 0; i--) {
		printf("%c", ans[i]);
	}
 return 0;
}
```

*其实这道才是最难的 不过非常好理解*

首先，以字符串的形式输入数字，接下来需要借助`int charNum(char c)`

把字母转换成数字，随后转换成十进制；

接下来可以利用==取余==的方式再借助==指针==逐个数字输入`char numChar(int  x)`(不要忘记再转回字母)；==注意这数字是倒着的==

利用指针倒着输出这串数字即可；









