## 常用属性速查表

| 属性                     | 类型      | 默认值 | 说明                  |
| ------------------------ | --------- | ------ | --------------------- |
| `frame`                  | CGRect    | -      | 位置和尺寸            |
| `bounds`                 | CGRect    | -      | 自身坐标尺寸          |
| `center`                 | CGPoint   | -      | 中心点 (相对于父视图) |
| `backgroundColor`        | UIColor   | nil    | 背景色                |
| `alpha`                  | CGFloat   | 1.0    | 透明度                |
| `hidden`                 | BOOL      | NO     | 是否隐藏              |
| `opaque`                 | BOOL      | YES    | GPU渲染提示           |
| `clipsToBounds`          | BOOL      | NO     | 裁剪子视图            |
| `userInteractionEnabled` | BOOL      | YES    | 响应交互              |
| `tag`                    | NSInteger | 0      | 视图标识              |





|              | 在浅色模式的效果     | 在深色模式的效果     | 对应的系统语义颜色                |
| :----------- | :------------------- | :------------------- | :-------------------------------- |
| **类似黑色** | **黑色或深灰色文字** | **白色或浅灰色文字** | `[UIColor labelColor]`            |
| **类似白色** | **白色**             | **黑色**             | `[UIColor systemBackgroundColor]` |