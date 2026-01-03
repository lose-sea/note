# const修饰指针

# const修饰指针

---

const修饰指针有三种情况：

1. const修饰指针–>常量指针
2. const修饰常量–>指针常量
3. const既修饰指针,又修饰常量
- 常量指针

const int* p = &a;

**指针的指向可以改,指针指向的值不可以改**

```c
#include<iostream>
using namespace std;
int main() {

	int a = 0;
	int b = 0;
	const int* p = &a;
	//  常量指针
	// 指针的指向可以改，但是指针指向的值不可以改

	*p = 10; // 报错，指针指向的值不可改
	p = &b;

	return 0;
}

```

- 指针常量

int* const p = &a;

指针的指向不可以改,指针指向的值可以改

```c
int main() {
	int a = 0;
	int b = 0;
	int* const p = &a;
	// 指针常量
	// 指针的指向不可以改
	p = &b; // error 指针的指向不可以改
    *p = 20;

	return 0;
}

```

- const 既修饰指针又修饰常量
- 常量指针常量

指针的指向和指针指向的值都不可以改变

const int* const p = &a;

```c
int main() {
	int a = 0;
	int b = 0;
	const int* const p = &a;
	*p = 10;
	p = &b; //error 指针的指向和指针指向的值都不可以改
	return 0;
}

```