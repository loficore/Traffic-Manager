// 1. 基础类型与接口定义
interface User {
  id: number;
  name: string;
  role: "admin" | "user";
}

const currentUser: User = {
  id: 1,
  name: "Chen",
  role: "admin", // 💡 尝试在此处修改或补全
};

// 2. 函数类型推导测试
function getWelcomeMessage(user: User): string {
  // 💡 在 user. 后面敲一个点，应该弹出来 id, name, role 的补全项
  return `Hello, ${user.name}! Role: ${user.role}`;
}

// 3. 故意制造一个 TS 语法报错（测试错误红线/诊断提示）
const invalidUser: User = {
  id: "not-a-number", // ❌ TS 应该在此处报类型错误：Type 'string' is not assignable to type 'number'
  name: "Test",
};

console.log(getWelcomeMessage(currentUser));
