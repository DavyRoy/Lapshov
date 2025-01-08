kubectl create -n eva secret tls eva-tls --cert=my-domain.ru.pem --key=my-domain.ru.key
kubectl create -n eva secret tls redis-tls --cert=redis.pem --key=redis.key
