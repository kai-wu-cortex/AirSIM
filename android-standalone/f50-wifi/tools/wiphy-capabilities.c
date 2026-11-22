/* Read-only nl80211 capability probe: never changes interfaces or connections. */
#include <errno.h>
#include <linux/genetlink.h>
#include <linux/netlink.h>
#include <linux/nl80211.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int valid(const struct nlattr *a, int n) {
    return n >= (int)sizeof(*a) && a->nla_len >= sizeof(*a) && a->nla_len <= n;
}
#define EACH(a, data, size) \
    for (int left = (size), once = 1; once; once = 0) \
        for (struct nlattr *a = (struct nlattr *)(data); valid(a, left); \
             left -= NLA_ALIGN(a->nla_len), a = (void *)((char *)a + NLA_ALIGN(a->nla_len)))
static void *payload(const struct nlattr *a) { return (char *)a + NLA_HDRLEN; }
static int length(const struct nlattr *a) { return a->nla_len - NLA_HDRLEN; }
static unsigned type(const struct nlattr *a) { return a->nla_type & NLA_TYPE_MASK; }
static uint32_t u32(const struct nlattr *a) { uint32_t v=0; if(length(a)>=4)memcpy(&v,payload(a),4); return v; }
static int request(int fd, int family, int cmd, int flags, int attr, const void *value, int size) {
    char data[512] = {0};
    struct nlmsghdr *h=(void *)data;
    struct genlmsghdr *g=(void *)(h+1);
    h->nlmsg_len=NLMSG_LENGTH(GENL_HDRLEN); h->nlmsg_type=family;
    h->nlmsg_flags=NLM_F_REQUEST|flags; h->nlmsg_seq=cmd;
    g->cmd=cmd; g->version=1;
    if(attr>=0){struct nlattr *a=(void *)(data+h->nlmsg_len);a->nla_type=attr;a->nla_len=NLA_HDRLEN+size;
        if(size)memcpy(payload(a),value,size);h->nlmsg_len+=NLA_ALIGN(a->nla_len);}
    struct sockaddr_nl kernel={.nl_family=AF_NETLINK};
    return sendto(fd,data,h->nlmsg_len,0,(void *)&kernel,sizeof(kernel));
}
static void combinations(struct nlattr *outer) {
    EACH(combo,payload(outer),length(outer)) {
        printf("combination:");
        EACH(a,payload(combo),length(combo)) {
            if(type(a)==NL80211_IFACE_COMB_MAXNUM)printf(" max_interfaces=%u",u32(a));
            if(type(a)==NL80211_IFACE_COMB_NUM_CHANNELS)printf(" channels=%u",u32(a));
            if(type(a)==NL80211_IFACE_COMB_LIMITS) {
                EACH(limit,payload(a),length(a)) {
                    printf(" [");
                    EACH(item,payload(limit),length(limit)) {
                        if(type(item)==NL80211_IFACE_LIMIT_MAX)printf("max=%u ",u32(item));
                        if(type(item)==NL80211_IFACE_LIMIT_TYPES) {
                            printf("types=");EACH(t,payload(item),length(item))printf("%u,",type(t));
                        }
                    }
                    printf("]");
                }
            }
        }
        puts("");
    }
}
int main(void) {
    int fd=socket(AF_NETLINK,SOCK_RAW,NETLINK_GENERIC);
    if(fd<0){perror("socket");return 1;}
    struct timeval timeout={.tv_sec=5};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    struct sockaddr_nl local={.nl_family=AF_NETLINK};
    if(bind(fd,(void *)&local,sizeof(local))<0){perror("bind");return 1;}
    char buf[65536];int family=-1;
    if(request(fd,GENL_ID_CTRL,CTRL_CMD_GETFAMILY,0,CTRL_ATTR_FAMILY_NAME,"nl80211",8)<0){perror("request");return 1;}
    int n=recv(fd,buf,sizeof(buf),0);if(n<0){perror("recv family");return 1;}
    for(struct nlmsghdr *h=(void *)buf;NLMSG_OK(h,(unsigned)n);h=NLMSG_NEXT(h,n)) {
        if(h->nlmsg_type==NLMSG_ERROR){printf("family_error=%d\n",((struct nlmsgerr *)NLMSG_DATA(h))->error);return 1;}
        EACH(a,(char *)NLMSG_DATA(h)+GENL_HDRLEN,h->nlmsg_len-NLMSG_HDRLEN-GENL_HDRLEN)
            if(type(a)==CTRL_ATTR_FAMILY_ID && length(a)>=2){uint16_t v;memcpy(&v,payload(a),2);family=v;}
    }
    if(family<0){puts("family missing");return 1;}
    if(request(fd,family,NL80211_CMD_GET_WIPHY,NLM_F_DUMP,NL80211_ATTR_SPLIT_WIPHY_DUMP,NULL,0)<0){perror("request wiphy");return 1;}
    while((n=recv(fd,buf,sizeof(buf),0))>0) {
        for(struct nlmsghdr *h=(void *)buf;NLMSG_OK(h,(unsigned)n);h=NLMSG_NEXT(h,n)) {
            if(h->nlmsg_type==NLMSG_DONE){close(fd);return 0;}
            if(h->nlmsg_type==NLMSG_ERROR){printf("wiphy_error=%d\n",((struct nlmsgerr *)NLMSG_DATA(h))->error);return 1;}
            EACH(a,(char *)NLMSG_DATA(h)+GENL_HDRLEN,h->nlmsg_len-NLMSG_HDRLEN-GENL_HDRLEN) {
                if(type(a)==NL80211_ATTR_WIPHY)printf("wiphy=%u\n",u32(a));
                if(type(a)==NL80211_ATTR_INTERFACE_COMBINATIONS)combinations(a);
                if(type(a)==NL80211_ATTR_SUPPORTED_IFTYPES){printf("supported_types=");EACH(t,payload(a),length(a))printf("%u,",type(t));puts("");}
            }
        }
    }
    perror("recv wiphy");return 1;
}
