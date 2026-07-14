# 1.string

# string

---

string 字符串其实是一种更加高级的封装,string字符串中包含大量的方法,这些方法使得字符串的操作变得更加简单

在C++中将字符串直接作为一种类型,也就是string类型,使用string类型创建的对象就是C++的字符串

注意: 使用C++中提供的string时, 必须添加头文件<string>

```c
string s1;
string s2 = "hello, world";

```

也可以用其他方式初始化 ,

```c
string s3("hello, world");

```

注意:这种方式只能是初始化,不能用于后赋值

```c
string s3;
s3("hello, world");  // error

```

string 类型可以直接赋值

例如:

```c
s2 = "abc";
s3 = "hello, world";
s2 = s3; // 赋值
cout << "s2: " << s2 << endl; // hello world

```

可以用 ‘+’来拼接两个字符串

```c
    string s1 = "hello, ";
    string s2 = "world!";
    string s3 = s1 + s2;
    cout << s3 << endl;   // hello, world!

```

没有‘-’操作

```c
    string s1 = "hello, world";
    string s2("world");
    string s3 = s1 - s2; // error: 不支持减法操作
    cout << "s3: " << s3 << endl;

```

## string字符串的输入

### cin的方式

可以直接使用cin 给 string类型的字符串中输入一个字符串的数据

```c
    string s1;
    cin >> s1;  // hello world
    cout << "s1: " << s1 << endl; // s1: hello  不能读取空格后的内容

```

### getline的方式

getline是C++标准库中的一个函数,用于从输入流中读取一行文本,并i将其存储为字符串

getline函数有两种不同的形式,分别对应着字符串的结束方式.

```c
istream getline (istream is, string str);

istream getline (istream is, string str, char deline);

```

> istream 是输入流类型, cin 是 istream 类型的标准输入流对象
> 
> 
> `ostream` 是输出流类型, cout 是ostream 类型的标准输出流对象
> 
> getline 函数是输入流中读取一行文本信息,所有如果是在标准输入流(键盘)中读取数据,就可以传 cin 给第一个参数
> 

第一种 getline 函数是以换行符‘\n’作为字符串的结束标志,它的一般格式是

```c
getline (cin, string str);
// cin -- 表示从输入流中读取数据
// str -- 是存放读取的信息的字符串

```

```c
    string s1;
    getline(cin, s1); // hello world
    cout << "s1: " << s1 << endl; // s1: hello world

```

这种形式的getline 函数从输入流(例如cin)中读取文本,直到遇到换行符(‘\n’)为止,然后将读取的文本(**不包括换行符**)存储到string 类型的变量 str 中

第二种 getline 函数允许用户自定义结束标志,它的一般格式是 :

```c
getline (cin, string str, char deline);

```

这种形式的getline 函数从输入流(例如cin)中读取文本,直到遇到用户指定的结束字符(deline)为止,然后将读取的文本(**不包括结束标志字符**)存储到string 类型的变量 str 中

```c
    string s1;
    getline(cin, s1, 'r');  // hello world
    cout << "s1: " << s1 << endl; // s1: hello wo

```

## size()

string 中提供了 size() 函数用于获取字符串长度

在C++中关于字符串的操作函数都是包含在string 中的,所有需要调用这些函数的时候, 通常需要用`.`点运算符

```c
    string s1;
    string s2 = "hello";
    string s3 = "abc      123";
    cout << s1.size() << endl;  // 0
    cout << s2.size() << endl;  // 5
    cout << s3.size() << endl;  // 11

```

```c
    string str1;
    cin >> str1;
    cout << str1 << endl;  // hello
    cout << str1.size() << endl; // 5

```

	string 类型字符串也是有下标的,下标从0开始

逐个打印字符串中的字符

```c
    string str = "hello world";
    cout << str << endl;  // hello world
    int sz = str.size();
    for (int i = 0; i < sz; i++) {
        cout << str[i] << " "; // h e l l o   w o r l d
    }

```

## 迭代器(iterator)

迭代器是一种对象,他可以用来遍历容器, (比如string)中的元素,迭代器的作用类似于指针或者数组下标

访问迭代器指向的值,需要解引用(*);

### begin() 和 end()

begin():  返回指向字符串第一个字符的迭代器,需要一个迭代器的变量来接收

end(): 返回指向**字符串最后一个字符的下一个位置**的迭代器 (改位置不属于字符串).

string中begin() 和 end() 返回的迭代器的类型是 string::inerator

> 迭代器是可以进行大小比较,也可以进行‘+’或者‘-’整数运算的
> 
> 
> 比如it++, 就是让迭代器前进一步,it–就是让迭代器退后一步
> 
> 同一个容器的两个迭代器也可以相减,相减结果的绝对值,是两个迭代器中间元素的个数
> 

```c
    string str = "abcdef";
    string::iterator it1 = str.begin();
    string::iterator it2 = str.end();
    int n = it1 - it2;
    cout << n << endl;  // -6

```

比较大小

```c
   // 比较大小
    if(it1 < it2) {
        cout << "it1 小于 it2" << endl;
    }

    else {
        cout << "it1 不小于 it2" << endl;
    }

```

解引用操作

```c
 // 解引用操作
cout << *it1 << endl;  // a

```

遍历

```c
    for (string::iterator it1 = str.begin(); it1 < str.end(); it1++) {
        cout << *it1 << " ";
    } // a b c d e f

```

倒序遍历

```c
    // 倒序遍历
    for (auto it2 = str.end(); it2 >= it1; it2--) {
        cout << *it2 << " ";
    }   // f e d c b a

```

## 字符串中的+= 和+运算

string 类型的字符是支持+ 和 +=运算的,这里的本质是string中重载了operator这个操作符

```c
    string s1 = "Hello ";
    string s2 = "World";
    s1 += s2; // 使用 += 运算符连接字符串
    cout << "使用 += 运算符连接字符串: " << s1 << endl;

```

```c
    cout << s1 + "world" << endl; // 使用 + 运算符连接字符串字面值
    string  s3 = s1 + s2;
    cout << s3 << endl;         // 使用 + 运算符连接两个字符串对象

```

### push_back

用于在字符串尾部插入一个字符

```c
    string s = "abc ";
    s.push_back('h');
    s.push_back('e');
    s.push_back('l');
    s.push_back('l');
    s.push_back('o');
	cout << s << endl; //abc hello

```

连续插入

```c
    string str;
    char c = 0;
    for (c = 'a'; c <= 'z'; c++) {
        str.push_back(c);
    }
    cout << str << endl;  // abcdefghijklmnopqrstuvwxyz

```

### pop_back()

用于删除字符串中尾部的一个字符

```c
    string str = "hello world";
    str.pop_back();
    cout << str << endl; //hello worl

```

当字符串为空时再去调用pop_back是标准**未定义的行为**

循环删除字符串的元素

```c
	string str = "hello world";
	int sz = str.size();
	while (sz >= 2 ) {

		str.pop_back();
		sz--;
	}
	cout << str << endl; // h
	cout << sz << endl;  // 1

```

### insert

---

在字符中的某个中间的某个位置插入一个字符串

```c
string insert ( size_t pos, const string& str); // pos位置前面插入一个string字符串
string insert ( size_t pos, const char* s);  	// pos位置前面插入一个c风格的字符串
string insert ( size_t pos, size_t t, char c); 	// pos位置前面插入n个字符c

```

```c
    string str1 = "hello world";
    string str2 = "xxx";
    str1.insert(5, str2);
    cout << str1 << endl; //helloxxx world

```

```c
    string str1 = "hello world";
    char str2[] = "yyy";
    str1.insert(5, str2);
    cout << str1 << endl; //helloyyy world

```

```c
    string str1 = "hello world";
    str1.insert(4, 3, 'x');
    cout << str1 << endl; // hellxxxo world

```

### find

finf() 函数用于查找字符串中指定子串/字符,并返回子串/字符在字符串中第一次出现的位置

```c
size_t find ( const string& str, size_t pos = 0) const;  // 查找string类型的字符串str, 默认是从头开始,pos可以指定位置开始
size_t find ( const char* s, size_t pos = 0) const; // 查找c风格的字符串s,默认是从头开始,pos可以指定位置开始
size_t find (const char* s, size_t pos, size_t n) const;  // 在字符串的pos位置开始查找c风格的字符串s中的前n个字符
size_t find ( char c, size_t pos = 0) coust; 	// 查找字符,默认从头开始,pos可以指定位置开始

```

返回值;

> 若找到,返回子串/字符在字符串中第一次出现的起始下标位置
> 
> 
> 若未找到,返回一个整数值npos,通过判断find()函数的返回值是否等于npos就能知道是否查找到子串或者字符
> 

**注意: 即使指定起始位置不是开头,返回的下标是相对于起始位置而言的**

```c
    string s = "hello world hello everyone";
    string str = "llo";
    size_t n = s.find(str);
    cout << n << endl; //2

```

从上次找到的位置接着查找

```c
    string s = "hello world hello everyone";
    string str = "llo";
    size_t n = s.find(str);
    cout << n << endl; //2

    n = s.find(str, n + 1);
    cout << n << endl; // 14

```

也可以使用C风格的字符串

```c
    string s = "hello world hello everyone";
    size_t n = s.find("llo");
    cout << n << endl; //2

    n = s.find("llo", n + 1);
    cout << n << endl; // 14

```

在字符串的pos位置开始查找c风格的字符串s中的前n个字符

```c
    string s = "hello world hello everyone";
    size_t n = s.find("word", 0, 3);
    cout << n << endl;  //6

```

也可以在当前位置接着查找

```c
    string s = "hello world hello everyone";
    size_t n = s.find("word", 0, 3);
    cout << n << endl;  //6
    size_t m = s.find("everyone", n + 1, 4);
    cout << m << endl;  //18

```

```c
//size_t find(const char* s, size_t pos, size_t n) const;  // 注意：这个只能用于char*，不能用于string!

    string s = "hello world hello everyone";
    string str = "llo";
    char ch[] = "llo";
    size_t n = s.find(str, 0, 3);   //error 要查找字符串前n个字符, 只能用于char*类型 不能用于string类型
    cout << n << endl;
    size_t m = s.find(ch, 0, 3);    // right
    cout << m << endl;

```

也可以用find()查找单个字符

```c
    string s = "hello world hello everyone";
    size_t n = s.find('o');
    cout << n << endl;  //4

```

要找字符下一个出现的位置,要从当前位置的一个位置开始查找

```c
    n = s.find('o', n + 1);
    cout << n << endl;  //7

```

没有找到

```c
    string s = "hello world hello everyone";
    string str = "xyz";
    size_t n = s.find(str);
    cout << n << endl;  //18446744073709551615 string::npos 返回-1, 表示未找到,被当作无符号整数最大值处理
    cout << string::npos << endl; //18446744073709551615

```

判断是否找到

```c
    string s = "hello world hello everyone";
    string str = "xyz";
    size_t n = s.find(str);
    cout << n << endl;  //18446744073709551615 string::npos 返回-1, 表示未找到,被当作无符号整数最大值处理
    if (n == string::npos) {
        cout << "找不到" << endl;
    } else {
        cout << "找到了" << endl;
    }

```

### substr()

substr()  函数用于截取字符串中指定位置指定长度的子串,

```c
string substr ( size_t pos = 0; size_t len = npos) coust;
// pos 的默认值是0, 也就是从下标0的位置开始读取
// len 的默认值是npos,意思是一直截取到字符串的末尾

```

`substr()`:如果函数不传参,就是从下标为0的位置开始截取,知道结尾,得到的是整个字符串

`substr(pos)`:从指定下标pos位置开始截取子串,知道结尾

`substr(pos, len)`:从指定下标pos位置开始截取长度为len的子串

```c
    string str = "hello world hello everyone";
    string s = str.substr(3, 6);
    cout << s << endl; // lo wor

```

```c
    string str = "hello world hello everyone";
    string s1 = str.substr(3, 6);
    cout << s1 << endl; // lo wor

    string s2 = str.substr(7);
    cout << s2 << endl; // rld hello everyone

    string s3 = str.substr();
    cout << s3 << endl; // hello world hello everyone

```

substr() 和 find() 经常是配合使用的,find负责找到位置,substr() 从这个位置向后获得获得字符串

**注意需要包含头文件<string>**

```c
    string str = "hello world hello everyone";
    size_t n =str.find("world");
    string s1 = str.substr(n, 10);
    cout << s1 << endl; //world hell

```

### compare() 字符串比较

字符串比较是按照字符的ASCLL码进行对比

= 返回 0

\> 返回 1

< 返回 -1

函数原型:

> int compare(const string &s) const; 
int conpare(const char* s) const;
> 

```c
int test01() {
	string str1("hello");
	string str2("xello");
	if (str1.compare(str2) == 0) {
		cout << "str1 等于 str2" << endl;
	}  else if (str1.compare(str2) < 0) {
		cout << "str1 小于 str2" << endl;
	} else {
		cout << "str1 大于 str2" << endl;
	}
}
int main() {
	test01();
	// str1 小于 str2
	return 0;
}

```

### 字符串的存取

获取字符有两种方法

- `char& operator[](int n)` 通过的方式获取
- `char& at(int n)` 通过at 的方式获取字符

方法一   通过[]的方式获取

```c
void test01() {
    string str("helle");
    for (int i = 0; i < str.size(); i++) {
        cout << str[i] << " ";
    }
    cout << endl;
}

```

方法二  通过at的方式获取

```c
void test02() {
    string str("helle");
    for (int i = 0; i < str.size(); i++) {
        cout << str.at(i) << " ";
    }
    cout << endl;
}

```

## string的关系运算

string类型是C++中封装类型也就是非内置类型,需要让他忙也支持关系运算,这里就涉及到**运算符的重载**,这些重载就使得string的字符也可以支持关系运算

```c
    // s1 == s2;
    s1 == s2;
    bool operator== (const string& lhs, const string& rhs); // 使用方式 s1 == s2
    bool operator== (const char*   lhs, const string& rhs); // 使用方式 s1 == s2
    bool operator== (const string& lhs, const char*   rhs); // 使用方式 s1 == s2
    // 不能使用  bool operator== (const char*   lhs, const char*   rhs); // 使用方式 s1 == s2
    // 无法比较两个c风格字符串是否相等

```

无法比较两个c风格字符串是否相等

其他运算符同理

字符串的比较是基于字典序进行的,比较的是对应位置上的字符的ASCLL值的大小,比较的不是字符串的长度

```c

    "abc" < "aq" ; // 'b' 的ASCLLI值小于 'q' 的ASCII值, 所以返回true
    "abxdef" < "ff" // 'a' 的ASCII值小于 'f' 的ASCII值, 所以返回true
    "100" < "9" // '1' 的ASCII值小于 '9' 的ASCII值, 所以返回true

```

## string相关的函数

### stoi 和 stol

stoi 是将字符串转换成int 类型的值

stol 是将字符串转换成long int 类型的值

stoi 和 stol 非常类似

stoi 函数其实可以将一个string类型的字符串,转换为整型,

```c
int stoi (const strinf& str, size_t* idx = 0; int base = 10);
long int (const string& str, size_t* idx = 0; int base = 10);

```

- str – 表示被转换的string类型的字符串
- idx 是一个输出型函数,也就是这个通过这个参数会带回一个值,idx 是一个指针,需要在外边创建一个size_t类型的值,传递它的地址给idx ,这个参数会带回str中无法正常匹配数字的第一个字符的位置
- base 表示被解析的字符串中数字的进制位,可能是2, 8, 10, 16或者0 也可以自定义进制
    - 默认情况下这个值是10, 表示10进制数字
    - 如果传递的是2, 表示被解析的字符串是2进制的数字,最终会转换成10进制
    - 如果传递的是8, 表示被解析的字符串是8进制的数字,最终会转换成10进制
    - 如果传递的是16, 表示被解析的字符串是16进制的数字,最终会转换成10进制
    - 如果传递的值是0, 会根据字符串的内容的信息自动推导进制,
        - 比如:字符串中有0x,就认为是16进制
        - 0开头会被认为是8进制,最终转换成10进制

```c
    string str = "11x123";
    size_t idx = 0;
    int n = stoi(str, &idx); // 第三个参数不写则默认按十进制转换
    cout << "n = " << n << endl;  // n = 11
    cout << "idx = " << idx << endl;  // idx = 2 第一个非数字字符的位置

    n = stoi(str, &idx, 16); // 按十六进制转换
    cout << "n = " << n << endl;  // n = 17

    n = stoi(str, &idx, 6); // 按六进制转换
    cout << "n = " << n << endl;  // n = 7

```

如果不想要第二个参数,也可以直接传递NULL;

```c
    string str = "3.14159abc";
    int n = stoi(str, NULL);
    cout << "n = " << n << endl;  // n = 3

```

### stof 和 stod

stod 是将字符串转换成double类型的值,函数原型如下,和stoi函数比较的话,少了描述字符串中数字进制的参数,其他参数一致,stof是将字符串转换成float类型的值

```c
double stod (const string str, size_t* idx = 0);
float stof (const string str, size_t* idx = 0);

```

```c
    string str = "3.14acb145";
    size_t idx = 0;
    double m = stod(str, &idx);
    cout << "m = " << m << endl;  // m = 3. 14
    cout << "idx = " << idx << endl;  // idx = 4

```

也可以直接传递NULL

```c
    double n = stod(str, NULL);
    cout << "n = " << n << endl;  // n = 3.14

```

### to_string

---

```c
string to_string(intval);
string to_string (long val);
string to_string (long long val);
string o_string(unsignedval);
string to_string (unsigned long val);
string to_string (unsigned long long val);
string to_string (float val);
string to_string (double val);
string o_string (long double val);

```

to_string 函数可以将数字转换成字符串,从上述函数原型的角度看,可以将整型,浮点型转换成字符串型

```c

    int n = 155;
    string str = to_string(n);
    cout << "str = " << str << endl;  // str = 155

    double m = 3.14;
    string str2 = to_string(m);
    cout << "str2 = " << str2 << endl;  // str2 = 3.140000

```