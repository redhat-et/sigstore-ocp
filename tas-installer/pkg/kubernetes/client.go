package kubernetes

import (
	"fmt"
	"net/url"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

type KubernetesClient struct {
	Clientset         *kubernetes.Clientset
	ClusterBaseDomain string
	ClusterCommonName string
}

func InitKubeClient(kubeConfigPath string) (*KubernetesClient, error) {
	fmt.Printf("Using kube config found at %s\n", kubeConfigPath)
	kubeConfig, err := clientcmd.BuildConfigFromFlags("", kubeConfigPath)
	if err != nil {
		return nil, fmt.Errorf("error getting Kubernetes config: %w", err)
	}

	dns := kubeConfig.Host
	baseDomain, err := parseClusterDNS(dns)
	commonName := "apps." + baseDomain

	clientset, err := kubernetes.NewForConfig(kubeConfig)
	if err != nil {
		return nil, fmt.Errorf("error getting Kubernetes clientset: %w", err)
	}

	return &KubernetesClient{Clientset: clientset, ClusterBaseDomain: baseDomain, ClusterCommonName: commonName}, nil
}

func parseClusterDNS(dns string) (string, error) {
	parsedURL, err := url.Parse(dns)
	if err != nil {
		panic(err)
	}
	domain := parsedURL.Hostname()
	return domain, nil
}