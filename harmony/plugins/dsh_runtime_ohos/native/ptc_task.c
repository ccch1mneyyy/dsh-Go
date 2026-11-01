#define _GNU_SOURCE
#include <AbilityKit/native_child_process.h>
#include <napi/native_api.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#define CAP 8
struct task {int pid,exited,signal,fd[4],eof[4];};
static struct task tasks[CAP];static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;static int watching;
static void exited(int32_t pid,int32_t signal){pthread_mutex_lock(&mutex);for(int i=0;i<CAP;i++)if(tasks[i].pid==pid){tasks[i].exited=1;tasks[i].signal=signal;}pthread_mutex_unlock(&mutex);}
static napi_value num(napi_env e,int n){napi_value v;napi_create_int32(e,n,&v);return v;}
static void prop(napi_env e,napi_value o,const char*k,int n){napi_set_named_property(e,o,k,num(e,n));}
static int arg(napi_env e,napi_callback_info i){size_t n=1;napi_value v;int32_t x=-1;napi_get_cb_info(e,i,&n,&v,NULL,NULL);if(n)napi_get_value_int32(e,v,&x);return x>0?x:-1;}
static int patharg(napi_env e,napi_value v,char*out,size_t cap){size_t n=0;if(napi_get_value_string_utf8(e,v,NULL,0,&n)!=napi_ok||!n||n>=cap)return 0;if(napi_get_value_string_utf8(e,v,out,cap,&n)!=napi_ok)return 0;return strlen(out)==n&&out[0]=='/'&&!strstr(out,"..")&&!strchr(out,'|');}
static napi_value launch(napi_env e,napi_callback_info info){
 size_t count=4;napi_value a[4];char root[1024],cwd[64],script[1300],params[160];double messageLimit,heapLimit;
 napi_get_cb_info(e,info,&count,a,NULL,NULL);
 if(count!=4||!patharg(e,a[0],root,sizeof(root))||!patharg(e,a[1],cwd,sizeof(cwd))||strcmp(cwd,"/")||napi_get_value_double(e,a[2],&messageLimit)!=napi_ok||napi_get_value_double(e,a[3],&heapLimit)!=napi_ok||!(messageLimit>=1&&messageLimit<=134217728)||!(heapLimit>=16&&heapLimit<=4096)||messageLimit!=(int)messageLimit||heapLimit!=(int)heapLimit)return num(e,-1);
 snprintf(script,sizeof(script),"%s/opt/dsh/node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib/process.js",root);
 int source=open(script,O_RDONLY|O_NOFOLLOW);if(source<0)return num(e,-3);
 pthread_mutex_lock(&mutex);int index;for(index=0;index<CAP&&tasks[index].pid;index++){}if(index==CAP){close(source);pthread_mutex_unlock(&mutex);return num(e,-2);}
 int code=watching?0:OH_Ability_RegisterNativeChildProcessExitCallback(exited);if(code){close(source);pthread_mutex_unlock(&mutex);return num(e,-code);}watching=1;
 int pairs[4][2]={{-1,-1},{-1,-1},{-1,-1},{-1,-1}};Ability_ChildProcessConfigs*config=NULL;
 for(int j=0;j<4;j++)if(socketpair(AF_UNIX,SOCK_STREAM,0,pairs[j])||fcntl(pairs[j][0],F_SETFL,O_NONBLOCK)<0){code=-5;goto done;}
 config=OH_Ability_CreateChildProcessConfigs();if(!config){code=-6;goto done;}
 code=OH_Ability_ChildProcessConfigs_SetIsolationMode(config,NCP_ISOLATION_MODE_ISOLATED);if(code)goto done;
 code=OH_Ability_ChildProcessConfigs_SetIsolationUid(config,true);if(code)goto done;
 snprintf(params,sizeof(params),"%lu|%d|%d",(unsigned long)getuid(),(int)messageLimit,(int)heapLimit);
 NativeChildProcess_Fd f[5]={{"control",pairs[0][1],&f[1]},{"stdout",pairs[1][1],&f[2]},{"stderr",pairs[2][1],&f[3]},{"nativeStatus",pairs[3][1],&f[4]},{"script",source,NULL}};
 NativeChildProcess_Args args={.entryParams=params,.fdList={.head=f}};int32_t pid=-1;
 code=OH_Ability_StartNativeChildProcessWithConfigs("libdsh_ptc_child.so:DshPtcMain",args,config,&pid);
 if(!code){tasks[index]=(struct task){.pid=pid,.signal=-1};for(int j=0;j<4;j++){tasks[index].fd[j]=pairs[j][0];pairs[j][0]=-1;}}
 done:if(config)OH_Ability_DestroyChildProcessConfigs(config);close(source);for(int j=0;j<4;j++)for(int k=0;k<2;k++)if(pairs[j][k]>=0)close(pairs[j][k]);int result=code?(code>0?-code:code):tasks[index].pid;pthread_mutex_unlock(&mutex);return num(e,result);
}
static napi_value status(napi_env e,napi_callback_info info){
 int pid=arg(e,info);napi_value o;napi_create_object(e,&o);pthread_mutex_lock(&mutex);
 for(int i=0;i<CAP;i++){if(tasks[i].pid==pid){prop(e,o,"pid",pid);prop(e,o,"exited",tasks[i].exited);prop(e,o,"signal",tasks[i].signal);break;}}
 pthread_mutex_unlock(&mutex);return o;
}
static napi_value read_stream(napi_env e,napi_callback_info info){
 size_t count=3;napi_value a[3],o,buffer,bytes;double requested;int32_t pid,index;int error=EINVAL,eof=0;size_t length=0;unsigned char data[65536];
 napi_create_object(e,&o);napi_get_cb_info(e,info,&count,a,NULL,NULL);
 if(count==3&&napi_get_value_int32(e,a[0],&pid)==napi_ok&&napi_get_value_int32(e,a[1],&index)==napi_ok&&pid>0&&index>=0&&index<4&&napi_get_value_double(e,a[2],&requested)==napi_ok&&requested>=0&&requested<=65536&&requested==(int)requested){
  pthread_mutex_lock(&mutex);
  for(int i=0;i<CAP;i++){if(tasks[i].pid==pid){error=0;eof=tasks[i].eof[index];if(requested>0&&!eof){ssize_t size=read(tasks[i].fd[index],data,(size_t)requested);if(size>0)length=(size_t)size;else if(size==0){tasks[i].eof[index]=1;eof=1;}else error=(errno==EAGAIN||errno==EWOULDBLOCK)?0:errno;}break;}}
  pthread_mutex_unlock(&mutex);
 }
 void *destination;napi_create_arraybuffer(e,length,&destination,&buffer);if(length)memcpy(destination,data,length);napi_create_typedarray(e,napi_uint8_array,length,buffer,0,&bytes);napi_set_named_property(e,o,"bytes",bytes);prop(e,o,"eof",eof);prop(e,o,"error",error);return o;
}
static napi_value stop(napi_env e,napi_callback_info info){int pid=arg(e,info),owned=0;pthread_mutex_lock(&mutex);for(int i=0;i<CAP;i++)if(tasks[i].pid==pid&&!tasks[i].exited)owned=1;pthread_mutex_unlock(&mutex);return num(e,owned?OH_Ability_KillChildProcess(pid):-1);}
static napi_value release(napi_env e,napi_callback_info info){int pid=arg(e,info),ok=0;pthread_mutex_lock(&mutex);for(int i=0;i<CAP;i++)if(tasks[i].pid==pid&&tasks[i].exited&&tasks[i].eof[0]&&tasks[i].eof[1]&&tasks[i].eof[2]&&tasks[i].eof[3]){for(int j=0;j<4;j++)close(tasks[i].fd[j]);memset(&tasks[i],0,sizeof(tasks[i]));ok=1;}pthread_mutex_unlock(&mutex);return num(e,ok);}
static napi_value write_control(napi_env e,napi_callback_info info){
 size_t count=2,length=0,offset=0;napi_value a[2],buffer;napi_typedarray_type type;void*data=NULL;int32_t pid=-1;
 napi_get_cb_info(e,info,&count,a,NULL,NULL);if(count!=2||napi_get_value_int32(e,a[0],&pid)!=napi_ok||pid<=0||napi_get_typedarray_info(e,a[1],&type,&length,&data,&buffer,&offset)!=napi_ok||type!=napi_uint8_array||length>65536)return num(e,-1);
 int result=-1;pthread_mutex_lock(&mutex);for(int i=0;i<CAP;i++)if(tasks[i].pid==pid&&!tasks[i].exited){ssize_t n=send(tasks[i].fd[0],data,length,MSG_NOSIGNAL);result=n>=0?(int)n:((errno==EAGAIN||errno==EWOULDBLOCK)?0:-1);break;}pthread_mutex_unlock(&mutex);return num(e,result);
}
static napi_value end_control(napi_env e,napi_callback_info info){int pid=arg(e,info),result=-1;pthread_mutex_lock(&mutex);for(int i=0;i<CAP;i++)if(tasks[i].pid==pid){result=shutdown(tasks[i].fd[0],SHUT_WR);break;}pthread_mutex_unlock(&mutex);return num(e,result);}
static napi_value init(napi_env e,napi_value o){napi_property_descriptor p[]={{"read",0,read_stream,0,0,0,napi_default,0},{"launch",0,launch,0,0,0,napi_default,0},{"status",0,status,0,0,0,napi_default,0},{"write",0,write_control,0,0,0,napi_default,0},{"end",0,end_control,0,0,0,napi_default,0},{"stop",0,stop,0,0,0,napi_default,0},{"release",0,release,0,0,0,napi_default,0}};napi_define_properties(e,o,7,p);return o;}
static napi_module module={.nm_version=1,.nm_register_func=init,.nm_modname="dsh_ptc_task"};
__attribute__((constructor))static void register_module(void){napi_module_register(&module);}
