kubectl get rs -oname | grep my-request- | xargs kubectl delete

kubectl get launcherconfig -oname | grep launcher-config- | xargs kubectl delete
kubectl get inferenceserverconfig -oname | grep inference-server-config- | xargs kubectl delete
