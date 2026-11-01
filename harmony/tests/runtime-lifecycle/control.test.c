/* 直接编译实际记录实现；SDK/NAPI封装由正式控制桥编译验证。 */
#define DSH_CONTROL_TEST
#include "../../plugins/dsh_runtime_ohos/native/control.c"
#include <assert.h>
#include <stdio.h>
int main(void) {
 on_exit(7,9);
 for(int pid=1000;pid<3000;pid++) {
  on_exit(pid,0);assert(exit_signal(pid)==0);
  assert(forget_exit(pid)==1);assert(exit_signal(pid)==-1);
  assert(exit_signal(7)==9);
 }
 assert(forget_exit(999)==0);assert(exit_signal(7)==9);
 on_exit(8,0);on_exit(8,15);assert(exit_signal(8)==15);
 assert(forget_exit(8)==1);assert(forget_exit(8)==0);
 for(int pid=10;pid<10+EXIT_CAPACITY-1;pid++)on_exit(pid,0);
 on_exit(9999,0);assert(exit_signal(9999)==-2);
 assert(forget_exit(10)==1);assert(exit_signal(9999)==-2);
 on_exit(4000,0);assert(exit_signal(4000)==0);assert(exit_signal(7)==9);
 puts("控制器真实C回归通过：2000轮回收、兄弟记录、信号、溢出未知");
 return 0;
}
