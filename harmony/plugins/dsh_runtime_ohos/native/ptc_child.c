#define _GNU_SOURCE
#include <AbilityKit/native_child_process.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <unistd.h>
#include "ptc_loader.h"
static int task_status_fd=-1;static void(*stop_control_io)(void);
/* 退出前唤醒已授权流上在途UV工作，避免默认退出等待阻塞read。 */
__attribute__((visibility("default"))) void DshTaskShutdownIo(void){if(stop_control_io)stop_control_io();shutdown(1,SHUT_RDWR);shutdown(2,SHUT_RDWR);}
__attribute__((visibility("default"))) int DshTaskStatusFd(void){return task_status_fd;}
/* 只运行固定已校验PTC脚本，绝不将任意父工作目录静默替换为根目录。 */
__attribute__((visibility("default"))) void DshPtcMain(NativeChildProcess_Args args){
 const char *names[]={"control","stdout","stderr","nativeStatus","script"};int original[5]={-1,-1,-1,-1,-1},fd[5];
 for(NativeChildProcess_Fd *item=args.fdList.head;item;item=item->next){if(item->fdName)for(int i=0;i<5;i++)if(!strcmp(item->fdName,names[i]))original[i]=item->fd;}
 for(int i=0;i<5;i++){if(original[i]<0)return;fd[i]=fcntl(original[i],F_DUPFD_CLOEXEC,20);if(fd[i]<0)return;}
 for(int i=0;i<5;i++)if(original[i]>2)close(original[i]);
 task_status_fd=fd[3];
 unsigned long parentUid=0;unsigned int limit=0,heap=0;char extra;
 if(!args.entryParams||sscanf(args.entryParams,"%lu|%u|%u%c",&parentUid,&limit,&heap,&extra)!=3||parentUid==getuid()||limit<1||limit>134217728||heap<16||heap>4096)return;
 struct stat source;int flags=fcntl(fd[4],F_GETFL);
 if(flags<0||(flags&O_ACCMODE)!=O_RDONLY||fstat(fd[4],&source)||!S_ISREG(source.st_mode)||source.st_size<1||source.st_size>1048576||chdir("/"))return;
 if(dup2(fd[1],1)<0||dup2(fd[2],2)<0)return;close(fd[1]);close(fd[2]);
 int input=open("/dev/null",O_RDONLY);if(input<0||dup2(input,0)<0)return;if(input>2)close(input);
 clearenv();setenv("UV_USE_IO_URING","0",1);setenv("NO_COLOR","1",1);setenv("DSH_SUBPROCESS_CONTROL","pipe",1);
 char text[32];snprintf(text,sizeof(text),"%d",fd[0]);setenv("DSH_PTC_CONTROL_FD",text,1);snprintf(text,sizeof(text),"%d",fd[4]);setenv("DSH_PTC_SCRIPT_FD",text,1);snprintf(text,sizeof(text),"%u",limit);setenv("DSH_PTC_MAX_MESSAGE",text,1);
 Dl_info info;char directory[2048],library[2200];
 if(!dladdr((void*)DshPtcMain,&info)||!info.dli_fname||strlen(info.dli_fname)>=sizeof(directory))return;
 strcpy(directory,info.dli_fname);char *slash=strrchr(directory,'/');if(!slash)return;*slash=0;setenv("DSH_HARMONY_NATIVE_LIBRARY_DIR",directory,1);
 void *node=dlopen("libnode.so",RTLD_NOW|RTLD_GLOBAL);if(!node)return;
 snprintf(library,sizeof(library),"%s/libdsh_ptc_shutdown.so",directory);void *bridge=dlopen(library,RTLD_NOW|RTLD_LOCAL);int(*bind)(int)=bridge?(int(*)(int))dlsym(bridge,"DshPtcSetControlFd"):NULL;if(!bind||bind(fd[0]))return;stop_control_io=(void(*)(void))dlsym(bridge,"DshPtcShutdownRegistered");if(!stop_control_io)return;
 char heapFlag[64];snprintf(heapFlag,sizeof(heapFlag),"--max-old-space-size=%u",heap);
 const char *values[]={"node","--jitless","--wasm-jitless",heapFlag,"-e",DSH_PTC_LOADER};char *argv[7];char storage[16384];size_t used=0;
 for(int i=0;i<6;i++){size_t count=strlen(values[i])+1;if(used+count>sizeof(storage))return;memcpy(storage+used,values[i],count);argv[i]=storage+used;used+=count;}argv[6]=NULL;
 snprintf(library,sizeof(library),"%s/libdsh_ptc_embed.so",directory);void *embed=dlopen(library,RTLD_NOW|RTLD_LOCAL);
 int(*run)(int,char**,const char*)=embed?(int(*)(int,char**,const char*))dlsym(embed,"DshPtcRunEmbedded"):NULL;if(!run)return;
 int code=run(6,argv,DSH_PTC_LOADER);
 snprintf(library,sizeof(library),"%s/libdsh_ptc_exit.so",directory);void *observer=dlopen(library,RTLD_NOW|RTLD_NOLOAD);void(*returned)(int)=observer?(void(*)(int))dlsym(observer,"DshObserveNodeReturn"):NULL;if(returned)returned(code);
}
